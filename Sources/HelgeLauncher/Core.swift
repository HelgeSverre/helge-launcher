import AppKit

enum ItemIcon {
    case file(String)          // icon of a file/app path
    case symbol(String)        // SF Symbol name
    case emoji(String)
    case image(NSImage)
    case none
}

struct Action {
    var title: String
    /// Return true to keep the panel open after running.
    var run: @MainActor () -> Bool
}

/// Where the panel goes when an item is chosen.
enum Mode: Equatable {
    case root
    case clipboard
    case emoji
    case snippets
    case onepassword
    case ai
    case plugin(String)

    var title: String {
        switch self {
        case .root: return ""
        case .clipboard: return "Clipboard"
        case .emoji: return "Emoji"
        case .snippets: return "Snippets"
        case .onepassword: return "1Password"
        case .ai: return "AI"
        case .plugin(let n): return n
        }
    }
}

struct Item: Identifiable {
    var id: String
    var title: String
    var subtitle: String = ""
    var icon: ItemIcon = .none
    var keywords: [String] = []
    var accessory: String = ""
    /// actions[0] runs on ↵, actions[1] on ⌘↵.
    var actions: [Action] = []
    /// Opens a sub-mode instead of running an action.
    var opens: Mode? = nil
    var preview: String? = nil
    var score: Double = 0
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
            let wordStart = ti == 0 || " -_./(".contains(t[ti - 1]) ||
                (tOrig[ti].isUppercase && !tOrig[ti - 1].isUppercase)
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
        if lt == lq { score += 30 }
        else if lt.hasPrefix(lq) { score += 15 }
        else if lt.contains(lq) { score += 6 }
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
    struct Entry: Codable { var count: Int; var last: Double }
    private(set) var entries: [String: Entry] = [:]
    private let url = Paths.supportDir.appendingPathComponent("history.json")

    init() {
        if let d = try? Data(contentsOf: url), let e = try? JSONDecoder().decode([String: Entry].self, from: d) {
            entries = e
        }
    }

    func record(_ id: String) {
        var e = entries[id] ?? Entry(count: 0, last: 0)
        e.count += 1
        e.last = Date().timeIntervalSince1970
        entries[id] = e
        if let d = try? JSONEncoder().encode(entries) { try? d.write(to: url, options: .atomic) }
    }

    /// log-count weighted by a recency decay with a two-week half-life-ish curve.
    func boost(_ id: String) -> Double {
        guard let e = entries[id] else { return 0 }
        let days = max(0, (Date().timeIntervalSince1970 - e.last) / 86400)
        return log2(1 + Double(e.count)) * (0.35 + 0.65 / (1 + days / 14))
    }
}

func rank(_ items: [Item], query: String, limit: Int = 60) -> [Item] {
    let q = query.trimmingCharacters(in: .whitespaces)
    var out: [Item] = []
    for var it in items {
        if q.isEmpty {
            it.score = History.shared.boost(it.id)
        } else {
            guard let s = Fuzzy.best(q, it) else { continue }
            it.score = s + History.shared.boost(it.id) * 1.5
        }
        out.append(it)
    }
    out.sort { $0.score > $1.score }
    return Array(out.prefix(limit))
}

// MARK: - Helpers

enum Shell {
    /// Runs a program and returns stdout. Throws with stderr on non-zero exit.
    static func run(_ launchPath: String, _ args: [String], stdin: Data? = nil, env: [String: String] = [:], unset: [String] = [], timeout: TimeInterval = 30) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = [launchPath] + args
                var e = ProcessInfo.processInfo.environment
                e["PATH"] = Shell.path
                for (k, v) in env { e[k] = v }
                for k in unset { e.removeValue(forKey: k) }
                p.environment = e
                let out = Pipe(), err = Pipe(), inp = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = inp
                do { try p.run() } catch { cont.resume(throwing: error); return }
                if let stdin { inp.fileHandleForWriting.write(stdin) }
                try? inp.fileHandleForWriting.close()
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                if p.terminationStatus == 0 {
                    cont.resume(returning: data)
                } else {
                    let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    cont.resume(throwing: NSError(domain: launchPath, code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: msg.isEmpty ? "exit \(p.terminationStatus)" : msg]))
                }
            }
        }
    }

    /// GUI apps get a minimal PATH, so ask the user's interactive zsh once (same binaries as the terminal).
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
        return ["\(home)/.bun/bin", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
    }()
}

enum Pasteboard {
    static func copy(_ s: String, concealed: Bool = false) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        if concealed {
            pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
    }

    /// Copies, then sends ⌘V to the frontmost app. Needs Accessibility permission.
    @MainActor static func paste(_ s: String) {
        copy(s)
        Launcher.shared?.hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { sendCmdV() }
    }

    /// Without Accessibility the copy still happens; the helper opens so the paste works next time.
    @MainActor static func sendCmdV() {
        guard AXIsProcessTrusted() else {
            PermissionHelper.shared.start()
            return
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Clears the pasteboard after `seconds` if it still holds `value`.
    static func clear(after seconds: Int, ifStill value: String) {
        let change = NSPasteboard.general.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) {
            if NSPasteboard.general.changeCount == change, NSPasteboard.general.string(forType: .string) == value {
                NSPasteboard.general.clearContents()
            }
        }
    }
}

@MainActor func openURL(_ s: String) -> Bool {
    let expanded = NSString(string: s).expandingTildeInPath
    if expanded.hasPrefix("/") {
        NSWorkspace.shared.open(URL(fileURLWithPath: expanded))
    } else if let u = URL(string: s) {
        NSWorkspace.shared.open(u)
    }
    return false
}
