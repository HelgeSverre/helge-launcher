import Foundation

/// Runs `opencode serve` as a child process and talks to its v2 HTTP API.
final class OpenCode {
    static let shared = OpenCode()
    var config = AIConfig()

    private var process: Process?
    private var baseURL: URL?
    private let password = UUID().uuidString + UUID().uuidString
    private var startTask: Task<URL, Error>?
    private var handlers: [String: (Event) -> Void] = [:]
    private let lock = NSLock()

    enum Event {
        case delta(String)
        case tool(String)
        case done
        case failed(String)
    }

    private let workDir: URL = {
        let u = Paths.supportDir.appendingPathComponent("ai")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    /// Starts the server once; concurrent callers share the same start.
    func ensureStarted() async throws -> URL {
        if let u = baseURL, process?.isRunning == true { return u }
        if let t = startTask { return try await t.value }
        let t = Task { () throws -> URL in
            let u = try await self.launch()
            self.baseURL = u
            self.subscribe(u)
            return u
        }
        startTask = t
        do { return try await t.value } catch { startTask = nil; throw error }
    }

    private func launch() async throws -> URL {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [NSString(string: config.opencode).expandingTildeInPath, "serve", "--hostname", "127.0.0.1", "--port", "0"]
        p.currentDirectoryURL = workDir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Shell.path
        env["OPENCODE_SERVER_PASSWORD"] = password
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p

        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                var buf = ""
                let deadline = Date().addingTimeInterval(20)
                while Date() < deadline {
                    let d = out.fileHandleForReading.availableData
                    if d.isEmpty { break }
                    buf += String(decoding: d, as: UTF8.self)
                    if let r = buf.range(of: "http://127\\.0\\.0\\.1:[0-9]+", options: .regularExpression), let u = URL(string: String(buf[r])) {
                        // Keep draining stdout so the child never blocks on a full pipe.
                        DispatchQueue.global().async { while !out.fileHandleForReading.availableData.isEmpty {} }
                        cont.resume(returning: u)
                        return
                    }
                }
                cont.resume(throwing: NSError(domain: "opencode", code: 1, userInfo: [NSLocalizedDescriptionKey: "opencode serve did not start: \(buf.prefix(300))"]))
            }
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        baseURL = nil
        startTask = nil
    }

    private func request(_ path: String, method: String = "GET", body: Any? = nil) throws -> URLRequest {
        guard let base = baseURL else { throw NSError(domain: "opencode", code: 2) }
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.httpMethod = method
        let auth = Data("opencode:\(password)".utf8).base64EncodedString()
        r.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    private func call(_ path: String, method: String = "GET", body: Any? = nil) async throws -> [String: Any] {
        let req = try request(path, method: method, body: body)
        if ProcessInfo.processInfo.environment["HL_DEBUG"] != nil {
            FileHandle.standardError.write(Data("→ \(method) \(req.url!.absoluteString) \(String(decoding: req.httpBody ?? Data(), as: UTF8.self))\n".utf8))
        }
        let (d, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "opencode", code: (resp as? HTTPURLResponse)?.statusCode ?? 0,
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: d, as: UTF8.self).prefix(300).description])
        }
        return obj
    }

    /// Text-only answers plus web lookups; everything else (shell, edits) is denied.
    func createSession() async throws -> String {
        _ = try await ensureStarted()
        let body: [String: Any] = [
            "title": "Helge Launcher",
            "model": ["providerID": config.providerID, "id": config.modelID],
            "permissions": [
                ["action": "*", "resource": "*", "effect": "deny"],
                ["action": "webfetch", "resource": "*", "effect": "allow"],
                ["action": "websearch", "resource": "*", "effect": "allow"],
            ],
        ]
        let r = try await call("api/session", method: "POST", body: body)
        guard let id = (r["data"] as? [String: Any])?["id"] as? String else {
            throw NSError(domain: "opencode", code: 3, userInfo: [NSLocalizedDescriptionKey: "no session id"])
        }
        return id
    }

    func prompt(session: String, text: String, onEvent: @escaping (Event) -> Void) async throws {
        lock.withLock { handlers[session] = onEvent }
        var full = text
        if let sys = config.system, !sys.isEmpty { full = sys + "\n\n" + text }
        _ = try await call("api/session/\(session)/prompt", method: "POST", body: ["text": full])
    }

    func interrupt(session: String) async {
        _ = try? await call("api/session/\(session)/interrupt", method: "POST", body: [String: Any]())
    }

    /// One long-lived SSE connection; events are routed to the session's handler.
    private func subscribe(_ base: URL) {
        Task.detached { [weak self] in
            while let self, self.baseURL != nil {
                do {
                    let types = ["session.text.delta", "session.tool.called", "session.execution.succeeded",
                                 "session.execution.failed", "session.execution.interrupted"]
                    var comps = URLComponents(url: base.appendingPathComponent("api/event"), resolvingAgainstBaseURL: false)!
                    comps.queryItems = types.map { URLQueryItem(name: "types", value: $0) }
                    var r = try self.request("api/event")
                    r.url = comps.url
                    r.timeoutInterval = .infinity
                    let (bytes, _) = try await URLSession.shared.bytes(for: r)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        self.dispatch(Data(line.dropFirst(5).utf8))
                    }
                } catch {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    private func dispatch(_ json: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let type = obj["type"] as? String,
              let data = obj["data"] as? [String: Any],
              let sid = data["sessionID"] as? String,
              let h = lock.withLock({ handlers[sid] }) else { return }
        let ev: Event
        switch type {
        case "session.text.delta": ev = .delta(data["delta"] as? String ?? "")
        case "session.tool.called": ev = .tool((data["tool"] as? String) ?? (data["name"] as? String) ?? "tool")
        case "session.execution.succeeded", "session.execution.interrupted": ev = .done
        default: ev = .failed((data["error"] as? [String: Any])?["message"] as? String ?? "\(data["error"] ?? "failed")")
        }
        DispatchQueue.main.async { h(ev) }
    }
}
