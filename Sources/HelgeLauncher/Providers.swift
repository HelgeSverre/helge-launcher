import AppKit

// MARK: - Applications

final class AppIndex {
    static let shared = AppIndex()
    private(set) var apps: [(name: String, path: String)] = []
    private var lastScan = Date.distantPast

    private let roots = [
        "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    func refreshIfStale() {
        guard Date().timeIntervalSince(lastScan) > 30 else { return }
        scan()
    }

    func scan() {
        lastScan = Date()
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [(String, String)] = []
        func add(_ path: String) {
            let p = (path as NSString).standardizingPath
            guard seen.insert(p).inserted else { return }
            let name = fm.displayName(atPath: p).replacingOccurrences(of: ".app", with: "")
            out.append((name, p))
        }
        for root in roots {
            guard let list = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for f in list {
                let full = (root as NSString).appendingPathComponent(f)
                if f.hasSuffix(".app") {
                    add(full)
                } else if !f.hasPrefix("."), (try? fm.attributesOfItem(atPath: full)[.type] as? FileAttributeType) == .typeDirectory,
                          root.hasSuffix("Applications") {
                    // One level of sub-folders (e.g. "AURA Plugins", JetBrains Toolbox folders).
                    for g in (try? fm.contentsOfDirectory(atPath: full)) ?? [] where g.hasSuffix(".app") {
                        add((full as NSString).appendingPathComponent(g))
                    }
                }
            }
        }
        add("/System/Library/CoreServices/Finder.app")
        apps = out
    }

    var items: [Item] {
        apps.map { app in
            let id = "app:" + app.path
            return Item(
                id: id, title: app.name, subtitle: "", icon: .file(app.path),
                keywords: [URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent],
                accessory: "Application",
                actions: [
                    Action(title: "Open") {
                        History.shared.record(id)
                        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: .init())
                        return false
                    },
                    Action(title: "Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
                        return false
                    },
                ])
        }
    }
}

// MARK: - CleanShot X (URL scheme: cleanshot://<command>)

enum CleanShot {
    static let commands: [(id: String, url: String, title: String, symbol: String)] = [
        ("capture-area", "capture-area", "Capture Area", "crop"),
        ("record-screen", "record-screen", "Record Screen", "record.circle"),
        ("restore-recently-closed", "restore-recently-closed", "Restore Recently Closed", "arrow.uturn.backward"),
        ("capture-text-ocr", "capture-text", "Capture Text (OCR)", "text.viewfinder"),
        ("capture-previous-area", "capture-previous-area", "Capture Previous Area", "rectangle.dashed"),
        ("capture-window", "capture-window", "Capture Window", "macwindow"),
        ("capture-fullscreen", "capture-fullscreen", "Capture Fullscreen", "rectangle.inset.filled"),
        ("scrolling-capture", "scrolling-capture", "Scrolling Capture", "arrow.up.and.down.text.horizontal"),
        ("self-timer", "self-timer", "Self Timer", "timer"),
        ("open-history", "open-history", "Open Capture History", "clock.arrow.circlepath"),
        ("all-in-one", "all-in-one", "All-In-One", "square.grid.2x2"),
    ]

    static var items: [Item] {
        commands.map { c in
            let id = "cleanshot." + c.id
            return Item(
                id: id, title: c.title, subtitle: "CleanShot X", icon: .symbol(c.symbol),
                keywords: ["cleanshot", "screenshot " + c.title], accessory: "Command",
                actions: [Action(title: "Run") {
                    History.shared.record(id)
                    Launcher.shared?.hide()
                    // Let the panel disappear before CleanShot grabs the screen.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        NSWorkspace.shared.open(URL(string: "cleanshot://" + c.url)!)
                    }
                    return false
                }])
        }
    }
}

// MARK: - User commands from config

enum UserCommands {
    static func items(_ cfg: [CommandConfig]) -> [Item] {
        cfg.map { c in
            let id = "cmd:" + c.name
            return Item(
                id: id, title: c.name, subtitle: c.open ?? c.run ?? "",
                icon: c.icon.map { $0.count <= 2 ? .emoji($0) : .symbol($0) } ?? .symbol(c.run != nil ? "terminal" : "link"),
                keywords: c.keywords ?? [], accessory: "Command",
                actions: [Action(title: "Run") {
                    History.shared.record(id)
                    run(c)
                    return false
                }])
        }
    }

    @MainActor static func run(_ c: CommandConfig) {
        if let o = c.open { _ = openURL(o) }
        if let r = c.run {
            Task { _ = try? await Shell.run("/bin/zsh", ["-lc", r]) }
        }
    }
}

// MARK: - Emoji (generated from Unicode data; no bundled tables)

enum Emoji {
    static let all: [(char: String, name: String)] = {
        var out: [(String, String)] = []
        let ranges: [ClosedRange<UInt32>] = [0x1F300...0x1FAFF, 0x2600...0x27BF, 0x2B00...0x2BFF, 0x1F000...0x1F2FF, 0x2190...0x21FF, 0x2300...0x23FF]
        for r in ranges {
            for v in r {
                guard let s = Unicode.Scalar(v), s.properties.isEmoji, s.properties.isEmojiPresentation || r.lowerBound == 0x2600,
                      let n = s.properties.name else { continue }
                out.append((String(s), n.lowercased()))
            }
        }
        return out
    }()

    static var items: [Item] {
        all.map { e in
            Item(id: "emoji:" + e.char, title: e.name.capitalized, icon: .emoji(e.char),
                 actions: [
                    Action(title: "Paste") { History.shared.record("emoji:" + e.char); Pasteboard.paste(e.char); return false },
                    Action(title: "Copy") { History.shared.record("emoji:" + e.char); Pasteboard.copy(e.char); return false },
                 ])
        }
    }
}

// MARK: - Snippets

enum Snippets {
    /// Replaces `{name}` and `{date:FORMAT}` placeholders. Unknown placeholders are left as written.
    static func placeholders(_ text: String, now: Date = Date(), clipboard: () -> String = { NSPasteboard.general.string(forType: .string) ?? "" }) -> String {
        guard text.contains("{") else { return text }
        func fmt(_ pattern: String) -> String {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = pattern
            return df.string(from: now)
        }
        let regex = try! NSRegularExpression(pattern: "\\{([a-z]+)(?::([^}]*))?\\}")
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1))
            let arg = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : nil
            let value: String?
            switch (name, arg) {
            case ("date", nil): value = fmt("yyyy-MM-dd")
            case ("date", let f?): value = fmt(f)
            case ("time", nil): value = fmt("HH:mm")
            case ("datetime", nil): value = fmt("yyyy-MM-dd HH:mm")
            case ("iso", nil): value = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withInternetDateTime])
            case ("weekday", nil): value = fmt("EEEE")
            case ("timestamp", nil): value = String(Int(now.timeIntervalSince1970))
            case ("uuid", nil): value = UUID().uuidString.lowercased()
            case ("clipboard", nil): value = clipboard()
            default: value = nil
            }
            out += value ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// Placeholders, then a whole-text op:// reference is read from 1Password.
    /// nil when the reference could not be read (the reference itself is never pasted).
    @MainActor static func expand(_ text: String) async -> String? {
        var t = placeholders(text)
        if t.hasPrefix("op://"), !t.contains("\n") {
            do { t = try await OnePassword.shared.read(t) } catch {
                Launcher.shared?.toast("1Password: \(error.localizedDescription)")
                NSLog("Helge Launcher snippet: 1Password read failed: %@", error.localizedDescription)
                return nil
            }
        }
        return t
    }

    static func items(_ cfg: [SnippetConfig]) -> [Item] {
        cfg.map { s in
            let id = "snippet:" + s.name
            return Item(
                id: id, title: s.name, subtitle: s.text.hasPrefix("op://") ? s.text : String(s.text.prefix(80)).replacingOccurrences(of: "\n", with: " "),
                icon: .symbol("text.quote"), keywords: [s.keyword].compactMap { $0 }, accessory: "Snippet",
                actions: [
                    Action(title: "Paste") {
                        History.shared.record(id)
                        Task { @MainActor in if let t = await expand(s.text) { Pasteboard.paste(t) } }
                        return false
                    },
                    Action(title: "Copy") {
                        History.shared.record(id)
                        Task { @MainActor in if let t = await expand(s.text) { Pasteboard.copy(t) } }
                        return false
                    },
                ],
                preview: s.text.hasPrefix("op://") ? nil : s.text)
        }
    }
}
