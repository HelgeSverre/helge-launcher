import AppKit
import Carbon

enum ItemIcon {
    /// The file's or app's own icon.
    case file(String)
    case symbol(String)
    case emoji(String)
    case none

    /// Config and plugin icon strings: a path (`/…` or `~/…`), an SF Symbol name (lowercase
    /// letters, digits and dots), or otherwise text such as an emoji.
    init(spec: String) {
        if spec.hasPrefix("/") || spec.hasPrefix("~") {
            self = .file(NSString(string: spec).expandingTildeInPath)
        } else if spec.range(of: "^[a-z0-9.]+$", options: .regularExpression) != nil {
            self = .symbol(spec)
        } else {
            self = .emoji(spec)
        }
    }
}

struct Action {
    enum Outcome {
        /// Hide the panel.
        case close
        /// Keep the panel open and refresh the list.
        case stay
    }

    var title: String
    /// What the action does, for headless listings (e.g. "open https://…").
    var detail = ""
    var run: @MainActor () -> Outcome

    init(title: String, detail: String = "", run: @escaping @MainActor () -> Outcome) {
        self.title = title
        self.detail = detail
        self.run = run
    }
}

enum Mode: Equatable {
    case root
    case clipboard
    case emoji
    case snippets
    case onepassword
    case ai
    /// Saved AI conversations.
    case chats
    /// Usage statistics: what was run, how often.
    case stats
    /// Running processes grouped by app.
    case processes
    /// TCP ports something listens on.
    case ports
    /// Dev tools left running after their session closed.
    case leftovers
    /// Free space and folders worth clearing.
    case storage
    case plugin(String)

    /// Modes fed by the process sampler while open.
    var samplesProcesses: Bool { self == .processes || self == .ports || self == .leftovers }

    /// Id of the root-list item that opens this mode; frecency is recorded under it.
    var itemID: String {
        switch self {
        case .root: return "mode.root"
        case .clipboard: return "mode.clipboard"
        case .emoji: return "mode.emoji"
        case .snippets: return "mode.snippets"
        case .onepassword: return "mode.onepassword"
        case .ai: return "mode.ai"
        case .chats: return "mode.chats"
        case .stats: return "mode.stats"
        case .processes: return "mode.processes"
        case .ports: return "mode.ports"
        case .leftovers: return "mode.leftovers"
        case .storage: return "mode.storage"
        case .plugin(let name): return "plugin:" + name
        }
    }

    /// Badge in the search field.
    var title: String {
        switch self {
        case .root: return ""
        case .clipboard: return "Clipboard"
        case .emoji: return "Emoji"
        case .snippets: return "Snippets"
        case .onepassword: return "1Password"
        case .ai: return "AI"
        case .chats: return "Chats"
        case .stats: return "Stats"
        case .processes: return "Processes"
        case .ports: return "Ports"
        case .leftovers: return "Leftovers"
        case .storage: return "Storage"
        case .plugin(let name): return name
        }
    }

    /// Root-list entries for every mode the config enables.
    static func entries(_ config: Config) -> [Item] {
        let modes: [Mode] =
            [
                .clipboard, .emoji, .snippets, .onepassword, .ai, .chats, .stats, .processes, .ports, .leftovers,
                .storage,
            ] + config.plugin.map { .plugin($0.name) }
        return modes.compactMap { $0.entry(config) }
    }

    /// The root-list item that opens this mode, or nil when the config disables it.
    func entry(_ config: Config) -> Item? {
        func item(_ title: String, _ symbol: String, subtitle: String = "", keywords: [String] = []) -> Item {
            Item(
                id: itemID,
                title: title,
                subtitle: subtitle,
                icon: .symbol(symbol),
                keywords: keywords,
                accessory: "Command",
                opens: self,
                historyKey: itemID
            )
        }
        switch self {
        case .root:
            return nil
        case .clipboard:
            return config.clipboard.enabled ? item("Clipboard History", "doc.on.clipboard", keywords: ["paste"]) : nil
        case .emoji:
            return item("Search Emoji & Symbols", "face.smiling", keywords: ["emoji"])
        case .snippets:
            return item("Search Snippets", "text.quote")
        case .onepassword:
            guard config.onepassword.enabled else { return nil }
            return item(
                "1Password",
                "key.horizontal",
                subtitle: "Search vault items",
                keywords: ["password", "op", "1p"]
            )
        case .ai:
            return config.ai.enabled
                ? item("AI Chat", "sparkles", subtitle: config.ai.model, keywords: ["ask", "ai"]) : nil
        case .chats:
            return config.ai.enabled
                ? item("AI Conversations", "clock", subtitle: "Earlier chats", keywords: ["history", "chats", "ai"])
                : nil
        case .stats:
            return item(
                "Usage Statistics",
                "chart.bar",
                subtitle: "Most used apps and commands",
                keywords: ["stats", "usage", "most used", "history"]
            )
        case .processes:
            return item(
                "Processes",
                "cpu",
                subtitle: "CPU, memory, quit apps",
                keywords: ["activity monitor", "task manager", "kill", "top", "htop", "ps", "memory", "cpu"]
            )
        case .ports:
            return item(
                "Ports",
                "network",
                subtitle: "What is listening on which port",
                keywords: ["lsof", "localhost", "server", "listening"]
            )
        case .leftovers:
            return item(
                "Leftover Dev Processes",
                "exclamationmark.triangle",
                subtitle: "Dev tools still running after their session closed",
                keywords: ["orphan", "mcp", "pkill", "node", "zombie"]
            )
        case .storage:
            return item(
                "Storage",
                "internaldrive",
                subtitle: "Free space and folders worth clearing",
                keywords: ["disk", "du", "df", "space", "cache", "clean"]
            )
        case .plugin(let name):
            guard let p = config.plugin.first(where: { $0.name == name }) else { return nil }
            return Item(
                id: itemID,
                title: p.name,
                subtitle: p.prefix.map { "\($0) …" } ?? "",
                icon: ItemIcon(spec: p.icon ?? "puzzlepiece.extension"),
                keywords: [p.prefix].compactMap { $0 },
                accessory: "Plugin",
                opens: self,
                historyKey: itemID
            )
        }
    }
}

struct Item: Identifiable {
    var id: String
    var title: String
    var subtitle = ""
    var icon = ItemIcon.none
    var keywords: [String] = []
    var accessory = ""
    /// `actions[0]` runs on ↵, `actions[1]` on ⌘↵, all are listed under ⌘K.
    var actions: [Action] = []
    /// Opens a mode instead of running an action.
    var opens: Mode?
    var preview: String?
    /// Frecency key: recorded when the item is used, read when ranking. nil: not ranked by use.
    var historyKey: String?
    var score: Double = 0
    /// Drawn as the calculator card.
    var calc: CalcCard?
    /// Drawn as a usage-statistics row.
    var usage: Usage?
    /// Drawn as a process, port, port-answer or storage row.
    var system: SystemRow?
    /// Group heading drawn above the first item of a run ("Today").
    var section: String?
}

// MARK: - Fuzzy matching

enum Fuzzy {
    /// Subsequence match with bonuses for prefix, word starts and consecutive runs. nil = no match.
    static func score(_ query: String, _ target: String) -> Double? {
        if query.isEmpty { return 0 }
        let q = Array(query.lowercased())
        let tOrig = Array(target)
        let t = Array(target.lowercased())
        guard q.count <= t.count else { return nil }

        var qi = 0
        var score = 0.0
        var prevMatch = -2
        var firstMatch = -1
        for (ti, c) in t.enumerated() where qi < q.count {
            guard c == q[qi] else { continue }
            var s = 1.0
            let wordStart =
                ti == 0 || " -_./(".contains(t[ti - 1]) || (tOrig[ti].isUppercase && !tOrig[ti - 1].isUppercase)
            if wordStart { s += 3 }
            if prevMatch == ti - 1 { s += 2 }
            if firstMatch < 0 { firstMatch = ti }
            score += s
            prevMatch = ti
            qi += 1
        }
        guard qi == q.count else { return nil }
        let lt = String(t)
        let lq = String(q)
        if lt == lq { score += 30 } else if lt.hasPrefix(lq) { score += 15 } else if lt.contains(lq) { score += 6 }
        score -= Double(firstMatch) * 0.2
        score -= Double(t.count - q.count) * 0.02
        return score
    }

    static func best(_ query: String, _ item: Item) -> Double? {
        var best = score(query, item.title)
        for k in item.keywords {
            if let s = score(query, k).map({ $0 - 2 }), s > (best ?? -.infinity) { best = s }
        }
        return best
    }
}

// MARK: - Frecency

final class History {
    static let shared = History()
    struct Entry: Codable {
        var count: Int
        var last: Double
        /// Uses per local day ("2026-11-24"), the last `History.keepDays` days; nil in entries
        /// recorded before days were kept.
        var days: [String: Int]?
    }
    /// How many days of per-day counts are kept.
    static let keepDays = 120
    private(set) var entries: [String: Entry] = [:]
    private let url: URL

    init(url: URL = Paths.supportDir.appendingPathComponent("history.json")) {
        self.url = url
        if let d = try? Data(contentsOf: url), let e = try? JSONDecoder().decode([String: Entry].self, from: d) {
            entries = e
        }
    }

    static func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func record(_ id: String, at now: Date = Date()) {
        var e = entries[id] ?? Entry(count: 0, last: 0)
        e.count += 1
        e.last = now.timeIntervalSince1970
        var days = e.days ?? [:]
        days[History.day(now), default: 0] += 1
        let cutoff = History.day(now.addingTimeInterval(-Double(History.keepDays) * 86400))
        e.days = days.filter { $0.key > cutoff }
        entries[id] = e
        save()
    }

    /// Removes an item's counts; it ranks as if never used.
    func forget(_ id: String) {
        entries[id] = nil
        save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(entries) { try? d.write(to: url, options: .atomic) }
    }

    /// log2(1 + count) × (0.35 + 0.65 / (1 + days / 14)).
    func boost(_ id: String) -> Double {
        guard let e = entries[id] else { return 0 }
        let days = max(0, (Date().timeIntervalSince1970 - e.last) / 86400)
        return log2(1 + Double(e.count)) * (0.35 + 0.65 / (1 + days / 14))
    }
}

func rank(_ items: [Item], query: String, limit: Int) -> [Item] {
    let q = query.trimmingCharacters(in: .whitespaces)
    var out: [Item] = []
    for var it in items {
        if q.isEmpty {
            it.score = it.historyKey.map(History.shared.boost) ?? 0
        } else {
            guard let s = Fuzzy.best(q, it) else { continue }
            it.score = s + (it.historyKey.map(History.shared.boost) ?? 0) * 1.5
        }
        out.append(it)
    }
    out.sort { $0.score > $1.score }
    return Array(out.prefix(limit))
}

// MARK: - Processes and pasteboard

enum Shell {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Runs `program` (looked up on `path`) and returns its stdout. Throws with stderr on a non-zero
    /// exit, on timeout (after terminating the process) and on task cancellation (same).
    /// Output that a backgrounded grandchild keeps open is not waited for beyond 0.2 s after exit.
    static func run(
        _ program: String,
        _ args: [String],
        env: [String: String] = [:],
        unset: [String] = [],
        cwd: URL? = nil,
        timeout: TimeInterval = 30
    ) async throws -> Data {
        try Task.checkCancellation()
        let p = makeProcess(program, args, env: env, unset: unset, cwd: cwd)
        let cancelled = LockedFlag()
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let stdoutData = LockedBuffer()
        let stderrData = LockedBuffer()
        let streams = DispatchGroup()
        for (pipe, buffer) in [(out, stdoutData), (err, stderrData)] {
            streams.enter()
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty {
                    h.readabilityHandler = nil
                    streams.leave()
                } else {
                    buffer.append(d)
                }
            }
        }
        let name = (program as NSString).lastPathComponent

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                let once = ResumeOnce(cont)
                p.terminationHandler = { proc in
                    _ = streams.wait(timeout: .now() + 0.2)
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    if proc.terminationStatus == 0 {
                        once.resume(returning: stdoutData.data)
                    } else {
                        let msg = stderrData.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        once.resume(
                            throwing: Failure(message: msg.isEmpty ? "\(name): exit \(proc.terminationStatus)" : msg)
                        )
                    }
                }
                if cancelled.isSet {
                    once.resume(throwing: CancellationError())
                    return
                }
                do {
                    try p.run()
                } catch {
                    once.resume(throwing: error)
                    return
                }
                if cancelled.isSet { p.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak p] in
                    guard let p, !once.isDone else { return }
                    once.resume(throwing: Failure(message: "\(name) timed out after \(String(format: "%g", timeout))s"))
                    if p.isRunning { p.terminate() }
                }
            }
        } onCancel: {
            cancelled.set()
            if p.isRunning { p.terminate() }
        }
    }

    /// Starts `zsh -lc command` on a background queue without waiting for it or reading its output.
    /// No-op under test runners.
    static func spawn(_ command: String) {
        guard !Paths.isTestRunner else { return }
        DispatchQueue.global().async {
            let p = makeProcess("/bin/zsh", ["-lc", command], env: [:], unset: [], cwd: nil)
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
            } catch {
                NSLog("Helge Launcher: could not run %@: %@", command, error.localizedDescription)
            }
        }
    }

    private static func makeProcess(
        _ program: String,
        _ args: [String],
        env: [String: String],
        unset: [String],
        cwd: URL?
    ) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [program] + args
        if let cwd { p.currentDirectoryURL = cwd }
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = path
        for (k, v) in env { e[k] = v }
        for k in unset { e.removeValue(forKey: k) }
        p.environment = e
        return p
    }

    /// Resolves `path` on a background queue; the first resolution runs an interactive zsh (up to 4 s).
    static func resolvedPath() async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async { cont.resume(returning: path) }
        }
    }

    /// PATH of an interactive zsh, resolved once; GUI apps get a minimal one.
    static let path: String = {
        let marker = "__HL_PATH__"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-ilc", "print -r -- \(marker)$PATH"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: killer)
            let d = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
            let text = String(decoding: d, as: UTF8.self)
            if let r = text.range(of: marker, options: .backwards) {
                let v = text[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if v.contains("/usr/bin") { return v }
            }
        }
        let home = NSHomeDirectory()
        return [
            "\(home)/.bun/bin", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            "/usr/sbin", "/sbin",
        ].joined(separator: ":")
    }()
}

enum Pasteboard {
    /// The system pasteboard; a private named pasteboard under test runners.
    static let board: NSPasteboard =
        Paths.isTestRunner
        ? NSPasteboard(name: NSPasteboard.Name("HelgeLauncherTests-\(getpid())"))
        : .general

    /// nspasteboard.org markers: clipboard managers skip items that carry one.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let skippedTypes: Set<String> = [
        concealedType.rawValue,
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
    ]

    static func copy(_ s: String) { write(s, concealed: false) }

    /// Copies `s` marked concealed and clears it after `clearAfter` seconds (0: never) if it is still there.
    static func copySecret(_ s: String, clearAfter: Int) {
        write(s, concealed: true)
        clear(after: clearAfter, ifStill: s)
    }

    /// Copies `s`, hides the launcher and sends ⌘V to the frontmost app.
    @MainActor static func paste(_ s: String) {
        copy(s)
        pasteCurrent()
    }

    @MainActor static func pasteSecret(_ s: String, clearAfter: Int) {
        copySecret(s, clearAfter: clearAfter)
        pasteCurrent()
    }

    /// Hides the launcher and sends ⌘V for what the pasteboard already holds.
    @MainActor static func pasteCurrent() {
        Launcher.shared?.hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { sendCmdV() }
    }

    private static func write(_ s: String, concealed: Bool) {
        board.clearContents()
        board.setString(s, forType: .string)
        if concealed { board.setString("", forType: concealedType) }
    }

    /// Without Accessibility, opens the permission helper instead; the copy stands. No-op under test runners.
    @MainActor private static func sendCmdV() {
        guard !Paths.isTestRunner else { return }
        guard AXIsProcessTrusted() else {
            PermissionHelper.shared.requestIfNeeded()
            return
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func clear(after seconds: Int, ifStill value: String) {
        guard seconds > 0 else { return }
        let change = board.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) {
            if board.changeCount == change, board.string(forType: .string) == value {
                board.clearContents()
            }
        }
    }
}

/// Effects outside the app: opening apps, files and URLs, and revealing files. No-ops under test runners.
@MainActor
enum Effects {
    static func open(_ url: URL) {
        guard !Paths.isTestRunner else { return }
        NSWorkspace.shared.open(url)
    }

    static func openApplication(_ url: URL) {
        guard !Paths.isTestRunner else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    static func reveal(_ url: URL) {
        guard !Paths.isTestRunner else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Opens a URL, or a file, folder or app path (`~` expanded), with its default handler.
@MainActor func openURL(_ s: String) {
    let expanded = NSString(string: s).expandingTildeInPath
    if expanded.hasPrefix("/") {
        Effects.open(URL(fileURLWithPath: expanded))
    } else if let u = URL(string: s) {
        Effects.open(u)
    }
}
