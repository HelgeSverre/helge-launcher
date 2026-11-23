import Foundation

enum AIEvent: Equatable {
    case delta(String)
    /// The model started or stopped reasoning.
    case thinking(Bool)
    case toolStarted(id: String, name: String)
    /// What the tool was asked: a search query or a URL.
    case toolInput(id: String, detail: String)
    /// `count`: search results, when the tool reports them.
    case toolEnded(id: String, ok: Bool, count: Int?, error: String?)
    case done
    case failed(String)

    var isTerminal: Bool {
        switch self {
        case .done, .failed: return true
        default: return false
        }
    }
}

/// A conversation on one server instance. Invalid once that server stops.
struct AISession: Equatable {
    let id: String
    let server: Int
}

enum AIError: LocalizedError, Equatable {
    case disabled
    case startFailed(String)
    case sessionLost
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .disabled: return "AI is disabled in the config"
        case .startFailed(let why): return "opencode serve did not start: \(why)"
        case .sessionLost: return "the opencode server restarted"
        case .http(let code, let body): return "opencode HTTP \(code): \(body)"
        }
    }
}

@MainActor
protocol AIBackend: AnyObject {
    func createSession() async throws -> AISession
    /// `onEvent` receives this prompt's events until `.done` or `.failed`.
    func prompt(_ session: AISession, text: String, onEvent: @escaping @MainActor (AIEvent) -> Void) async throws
    func interrupt(_ session: AISession) async
    /// Stops delivering events for the session.
    func release(_ session: AISession)
}

/// `opencode serve --stdio` child; it exits when its stdin pipe closes, including when this process dies.
/// idle → starting → running → idle (stop or exit).
@MainActor
final class OpenCode: AIBackend {
    static let shared = OpenCode()

    private(set) var config = AIConfig()

    private struct Server {
        let id: Int
        let process: Process
        let stdin: FileHandle
        let url: URL
        var events: Task<Void, Never>?
    }

    private enum State {
        case idle
        case starting(id: Int, task: Task<Int, Error>)
        case running(Server)
    }

    private var state = State.idle
    private var nextServerID = 1
    private struct Handler {
        let deliver: @MainActor (AIEvent) -> Void
        /// When the server accepted the prompt; `.distantFuture` until then.
        var accepted: Date = .distantFuture
    }

    private var handlers: [String: Handler] = [:]
    private let password = UUID().uuidString + UUID().uuidString
    var startTimeout: TimeInterval = 20

    private let workDir: URL = {
        let u = Paths.supportDir.appendingPathComponent("ai")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    // MARK: Lifecycle

    /// Stops the server when AI is disabled or the binary changed; prestarts it when enabled.
    func apply(_ new: AIConfig) {
        let restart = new.opencode != config.opencode || !new.enabled
        config = new
        if restart { stop() }
        if new.enabled { Task { _ = try? await ensureStarted() } }
    }

    /// Starts the server if needed; concurrent callers share one start.
    func ensureStarted() async throws -> Int {
        guard config.enabled else { throw AIError.disabled }
        switch state {
        case .running(let s):
            return s.id
        case .starting(_, let task):
            return try await task.value
        case .idle:
            let id = nextServerID
            nextServerID += 1
            let binary = NSString(string: config.opencode).expandingTildeInPath
            let task = Task { try await self.start(id: id, binary: binary) }
            state = .starting(id: id, task: task)
            return try await task.value
        }
    }

    private func start(id: Int, binary: String) async throws -> Int {
        let server: Server
        do {
            server = try await launch(id: id, binary: binary)
        } catch {
            if case .starting(let current, _) = state, current == id { state = .idle }
            throw error
        }
        guard case .starting(let current, _) = state, current == id else {
            terminate(server)
            throw AIError.startFailed("stopped while starting")
        }
        guard server.process.isRunning else {
            state = .idle
            throw AIError.startFailed("exited during startup")
        }
        var running = server
        running.events = subscribe(running)
        state = .running(running)
        return id
    }

    func stop() {
        switch state {
        case .running(let s): terminate(s)
        case .starting(_, let task): task.cancel()
        case .idle: break
        }
        state = .idle
        failAll("the opencode server stopped")
    }

    /// Closing stdin asks the server to exit; SIGTERM after 3 s.
    private func terminate(_ s: Server) {
        s.events?.cancel()
        try? s.stdin.close()
        let process = s.process
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if process.isRunning { process.terminate() }
        }
    }

    private func exited(serverID: Int) {
        guard case .running(let s) = state, s.id == serverID else { return }
        s.events?.cancel()
        state = .idle
        failAll("the opencode server exited")
    }

    private func failAll(_ message: String) {
        let pending = handlers
        handlers = [:]
        for h in pending.values { h.deliver(.failed(message)) }
    }

    private var runningServer: Server? {
        if case .running(let s) = state { return s }
        return nil
    }

    private func launch(id: Int, binary: String) async throws -> Server {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [binary, "serve", "--stdio", "--hostname", "127.0.0.1", "--port", "0"]
        p.currentDirectoryURL = workDir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = await Shell.resolvedPath()
        env["OPENCODE_SERVER_PASSWORD"] = password
        p.environment = env
        let stdin = Pipe()
        let stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.exited(serverID: id) }
        }
        do { try p.run() } catch { throw AIError.startFailed(error.localizedDescription) }

        do {
            let url = try await withTaskCancellationHandler {
                try await Self.readURL(from: stdout.fileHandleForReading, timeout: startTimeout)
            } onCancel: {
                p.terminate()
            }
            return Server(id: id, process: p, stdin: stdin.fileHandleForWriting, url: url)
        } catch {
            try? stdin.fileHandleForWriting.close()
            if p.isRunning { p.terminate() }
            throw error
        }
    }

    /// Reads stdout up to the `{"url": …}` line, then keeps draining it.
    private nonisolated static func readURL(from handle: FileHandle, timeout: TimeInterval) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let once = ResumeOnce(cont)
            let buffer = LockedBuffer()
            handle.readabilityHandler = { h in
                let data = h.availableData
                if data.isEmpty {
                    h.readabilityHandler = nil
                    once.resume(throwing: AIError.startFailed("exited: \(buffer.text.prefix(300))"))
                    return
                }
                guard !once.isDone else { return }
                buffer.append(data)
                for line in buffer.text.split(separator: "\n") {
                    if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                        let s = obj["url"] as? String, let url = URL(string: s)
                    {
                        once.resume(returning: url)
                        return
                    }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume(throwing: AIError.startFailed("no URL after \(Int(timeout))s: \(buffer.text.prefix(300))"))
            }
        }
    }

    // MARK: Sessions

    func createSession() async throws -> AISession {
        let serverID = try await ensureStarted()
        let body: [String: Any] = [
            "title": "Helge Launcher",
            "model": ["providerID": config.providerID, "id": config.modelID],
            "permissions": [
                ["action": "*", "resource": "*", "effect": "deny"],
                ["action": "webfetch", "resource": "*", "effect": "allow"],
                ["action": "websearch", "resource": "*", "effect": "allow"],
            ],
        ]
        let r = try await call("api/session", method: "POST", body: body, server: serverID)
        guard let id = (r["data"] as? [String: Any])?["id"] as? String else {
            throw AIError.http(200, "no session id")
        }
        return AISession(id: id, server: serverID)
    }

    func prompt(_ session: AISession, text: String, onEvent: @escaping @MainActor (AIEvent) -> Void) async throws {
        guard runningServer?.id == session.server else { throw AIError.sessionLost }
        handlers[session.id] = Handler(deliver: onEvent)
        var full = text
        if let sys = config.system, !sys.isEmpty { full = sys + "\n\n" + text }
        do {
            _ = try await call(
                "api/session/\(session.id)/prompt",
                method: "POST",
                body: ["text": full],
                server: session.server
            )
            handlers[session.id]?.accepted = Date()
        } catch {
            handlers[session.id] = nil
            throw error
        }
    }

    func interrupt(_ session: AISession) async {
        _ = try? await call(
            "api/session/\(session.id)/interrupt",
            method: "POST",
            body: [String: Any](),
            server: session.server
        )
    }

    func release(_ session: AISession) {
        handlers[session.id] = nil
    }

    // MARK: HTTP

    private func request(_ path: String, server: Server, method: String = "GET", body: Any? = nil) throws -> URLRequest
    {
        var r = URLRequest(url: server.url.appendingPathComponent(path))
        r.httpMethod = method
        r.setValue(
            "Basic \(Data("opencode:\(password)".utf8).base64EncodedString())",
            forHTTPHeaderField: "Authorization"
        )
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    private func call(_ path: String, method: String, body: Any?, server serverID: Int) async throws -> [String: Any] {
        guard let server = runningServer, server.id == serverID else { throw AIError.sessionLost }
        let req = try request(path, server: server, method: method, body: body)
        let (d, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw AIError.http(code, String(String(decoding: d, as: UTF8.self).prefix(300)))
        }
        return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }

    /// Finishes prompts accepted over 2 s ago whose session is no longer active.
    private func finishInactiveSessions(_ server: Server) async {
        guard !handlers.isEmpty,
            let r = try? await call("api/session/active", method: "GET", body: nil, server: server.id),
            let active = r["data"] as? [String: Any]
        else { return }
        let cutoff = Date().addingTimeInterval(-2)
        for (sid, h) in handlers where active[sid] == nil && h.accepted < cutoff {
            handlers[sid] = nil
            h.deliver(.done)
        }
    }

    /// One event stream per server, reconnecting after 1 s; each connection first finishes prompts
    /// whose final event may have been missed.
    private func subscribe(_ server: Server) -> Task<Void, Never> {
        let types = [
            "session.text.delta", "session.tool.called", "session.execution.succeeded",
            "session.execution.failed", "session.execution.interrupted", "session.reasoning.started",
            "session.reasoning.ended", "session.tool.input.started", "session.tool.success", "session.tool.failed",
        ]
        var comps = URLComponents(url: server.url.appendingPathComponent("api/event"), resolvingAgainstBaseURL: false)!
        let dump = ProcessInfo.processInfo.environment["HL_AI_EVENTS"] != nil
        comps.queryItems = dump ? [] : types.map { URLQueryItem(name: "types", value: $0) }
        guard var req = try? request("api/event", server: server) else { return Task {} }
        req.url = comps.url
        req.timeoutInterval = .infinity
        return Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    if (resp as? HTTPURLResponse)?.statusCode == 200 {
                        await self?.finishInactiveSessions(server)
                        for try await line in bytes.lines where line.hasPrefix("data:") {
                            if dump { FileHandle.standardError.write(Data((line + "\n").utf8)) }
                            self?.dispatch(Data(line.dropFirst(5).utf8))
                        }
                    }
                } catch {}
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// The input that says what a tool did: a query, a URL, else the first text value.
    nonisolated static func detail(_ input: Any?) -> String {
        guard let d = input as? [String: Any] else { return "" }
        for key in ["query", "url", "q", "path", "command"] { if let v = d[key] as? String { return v } }
        return d.values.compactMap { $0 as? String }.first ?? ""
    }

    /// Web search results come back as one "## [title](url)" heading per hit.
    nonisolated static func resultCount(_ content: Any?) -> Int? {
        guard let parts = content as? [[String: Any]] else { return nil }
        let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        let n = text.components(separatedBy: "\n").filter { $0.hasPrefix("## [") }.count
        return n > 0 ? n : nil
    }

    private func dispatch(_ json: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
            let type = obj["type"] as? String,
            let data = obj["data"] as? [String: Any],
            let sid = data["sessionID"] as? String,
            let handler = handlers[sid]?.deliver
        else { return }
        let event: AIEvent
        switch type {
        case "session.text.delta": event = .delta(data["delta"] as? String ?? "")
        case "session.reasoning.started": event = .thinking(true)
        case "session.reasoning.ended": event = .thinking(false)
        case "session.tool.input.started":
            event = .toolStarted(id: data["id"] as? String ?? "", name: data["name"] as? String ?? "tool")
        case "session.tool.called":
            event = .toolInput(id: data["id"] as? String ?? "", detail: OpenCode.detail(data["input"]))
        case "session.tool.success":
            event = .toolEnded(
                id: data["id"] as? String ?? "",
                ok: true,
                count: OpenCode.resultCount(data["content"]),
                error: nil
            )
        case "session.tool.failed":
            let message = (data["error"] as? [String: Any])?["message"] as? String
            event = .toolEnded(id: data["id"] as? String ?? "", ok: false, count: nil, error: message)
        case "session.execution.succeeded", "session.execution.interrupted": event = .done
        case "session.execution.failed":
            event = .failed((data["error"] as? [String: Any])?["message"] as? String ?? "\(data["error"] ?? "failed")")
        default:
            return
        }
        if event.isTerminal { handlers[sid] = nil }
        handler(event)
    }
}
