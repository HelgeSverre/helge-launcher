import AppKit

// MARK: - Applications

final class AppIndex {
    static let shared = AppIndex()
    private(set) var apps: [(name: String, path: String)] = []
    private var lastScan = Date.distantPast

    private let roots = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    func refreshIfStale() {
        guard Date().timeIntervalSince(lastScan) > 30 else { return }
        scan()
    }

    /// Apps in `roots`, one level of sub-folders of the `…/Applications` roots, and Finder.
    func scan() {
        lastScan = Date()
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [(String, String)] = []
        func add(_ path: String) {
            let p = (path as NSString).standardizingPath
            guard seen.insert(p).inserted else { return }
            let name = (fm.displayName(atPath: p) as NSString).deletingPathExtension
            out.append((name, p))
        }
        for root in roots {
            for f in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
                let full = (root as NSString).appendingPathComponent(f)
                if f.hasSuffix(".app") {
                    add(full)
                } else if !f.hasPrefix("."), root.hasSuffix("Applications"), isDirectory(full) {
                    for g in (try? fm.contentsOfDirectory(atPath: full)) ?? [] where g.hasSuffix(".app") {
                        add((full as NSString).appendingPathComponent(g))
                    }
                }
            }
        }
        add("/System/Library/CoreServices/Finder.app")
        apps = out
    }

    private func isDirectory(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeDirectory
    }

    var items: [Item] {
        apps.map { app in
            let url = URL(fileURLWithPath: app.path)
            return Item(
                id: "app:" + app.path,
                title: app.name,
                icon: .file(app.path),
                keywords: [url.deletingPathExtension().lastPathComponent],
                accessory: "Application",
                actions: [
                    Action(title: "Open") {
                        NSWorkspace.shared.openApplication(at: url, configuration: .init())
                        return .close
                    },
                    Action(title: "Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        return .close
                    },
                ],
                historyKey: "app:" + app.path
            )
        }
    }
}

// MARK: - CleanShot X (cleanshot://<command>)

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
            Item(
                id: "cleanshot." + c.id,
                title: c.title,
                subtitle: "CleanShot X",
                icon: .symbol(c.symbol),
                keywords: ["cleanshot", "screenshot " + c.title],
                accessory: "Command",
                actions: [
                    Action(title: "Run") {
                        // The panel must be off screen before the capture starts.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            NSWorkspace.shared.open(URL(string: "cleanshot://" + c.url)!)
                        }
                        return .close
                    }
                ],
                historyKey: "cleanshot." + c.id
            )
        }
    }
}

// MARK: - User commands

enum UserCommands {
    static func items(_ cfg: [CommandConfig]) -> [Item] {
        cfg.map { c in
            Item(
                id: "cmd:" + c.name,
                title: c.name,
                subtitle: c.open ?? c.run ?? "",
                icon: c.icon.map(ItemIcon.init(spec:)) ?? .symbol(c.run != nil ? "terminal" : "link"),
                keywords: c.keywords ?? [],
                accessory: "Command",
                actions: [
                    Action(title: "Run") {
                        run(c)
                        return .close
                    }
                ],
                historyKey: "cmd:" + c.name
            )
        }
    }

    @MainActor static func run(_ c: CommandConfig) {
        if let o = c.open { openURL(o) }
        if let r = c.run { Shell.spawn(r) }
    }
}

// MARK: - Emoji

enum Emoji {
    /// Emoji-presentation scalars from the Unicode tables, plus the 0x2600 block.
    static let all: [(char: String, name: String)] = {
        let ranges: [ClosedRange<UInt32>] = [
            0x1F300...0x1FAFF,
            0x2600...0x27BF,
            0x2B00...0x2BFF,
            0x1F000...0x1F2FF,
            0x2190...0x21FF,
            0x2300...0x23FF,
        ]
        var out: [(String, String)] = []
        for r in ranges {
            for v in r {
                guard let s = Unicode.Scalar(v),
                      s.properties.isEmoji,
                      s.properties.isEmojiPresentation || r.lowerBound == 0x2600,
                      let name = s.properties.name
                else { continue }
                out.append((String(s), name.lowercased()))
            }
        }
        return out
    }()

    static var items: [Item] {
        all.map { e in
            Item(
                id: "emoji:" + e.char,
                title: e.name.capitalized,
                icon: .emoji(e.char),
                actions: [
                    Action(title: "Paste") {
                        Pasteboard.paste(e.char)
                        return .close
                    },
                    Action(title: "Copy") {
                        Pasteboard.copy(e.char)
                        return .close
                    },
                ],
                historyKey: "emoji:" + e.char
            )
        }
    }
}

// MARK: - Placeholders

enum Placeholders {
    /// Replaces `{name}` and `{date:FORMAT}`; unknown placeholders are left as written.
    static func expand(
        _ text: String,
        now: Date = Date(),
        clipboard: () -> String = { Pasteboard.board.string(forType: .string) ?? "" }
    ) -> String {
        guard text.contains("{") else { return text }
        func format(_ pattern: String) -> String {
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
            case ("date", nil): value = format("yyyy-MM-dd")
            case ("date", let f?): value = format(f)
            case ("time", nil): value = format("HH:mm")
            case ("datetime", nil): value = format("yyyy-MM-dd HH:mm")
            case ("iso", nil): value = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withInternetDateTime])
            case ("weekday", nil): value = format("EEEE")
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
}

// MARK: - Snippets

enum Snippets {
    struct Expanded {
        let text: String
        /// Read from 1Password.
        let isSecret: Bool
    }

    /// Placeholders, then a whole-text `op://` reference is read from 1Password.
    /// nil when the reference couldn't be read; the reference itself is never returned.
    @MainActor static func expand(_ text: String) async -> Expanded? {
        let t = Placeholders.expand(text)
        guard t.hasPrefix("op://"), !t.contains("\n") else { return Expanded(text: t, isSecret: false) }
        do {
            return Expanded(text: try await OnePassword.shared.read(t), isSecret: true)
        } catch {
            Launcher.shared?.toast("1Password: \(error.localizedDescription)")
            NSLog("Helge Launcher snippet: 1Password read failed: %@", error.localizedDescription)
            return nil
        }
    }

    /// True when `target` is still frontmost and the launcher hasn't been shown since `showCount`.
    @MainActor static func canPaste(into target: NSRunningApplication?, showCount: Int?, launcher: Launcher? = nil) -> Bool {
        guard let target, NSWorkspace.shared.frontmostApplication == target else { return false }
        guard let launcher = launcher ?? Launcher.shared else { return true }
        return launcher.showCount == showCount && launcher.panel?.isVisible != true
    }

    /// Pastes when `canPaste`, else copies; secrets are cleared after `clear_after`.
    @MainActor static func deliver(_ e: Expanded, paste: Bool, target: NSRunningApplication?, showCount: Int? = nil) {
        let clearAfter = OnePassword.shared.config.clearAfter
        switch (paste && canPaste(into: target, showCount: showCount), e.isSecret) {
        case (true, true): Pasteboard.pasteSecret(e.text, clearAfter: clearAfter)
        case (true, false): Pasteboard.paste(e.text)
        case (false, true): Pasteboard.copySecret(e.text, clearAfter: clearAfter)
        case (false, false): Pasteboard.copy(e.text)
        }
    }

    static func items(_ cfg: [SnippetConfig]) -> [Item] {
        cfg.map { s in
            let isReference = s.text.hasPrefix("op://")
            return Item(
                id: "snippet:" + s.name,
                title: s.name,
                subtitle: isReference ? s.text : String(s.text.prefix(80)).replacingOccurrences(of: "\n", with: " "),
                icon: .symbol("text.quote"),
                keywords: [s.keyword].compactMap { $0 },
                accessory: "Snippet",
                actions: [
                    Action(title: "Paste") {
                        let target = NSWorkspace.shared.frontmostApplication
                        let shown = Launcher.shared?.showCount
                        Task { @MainActor in
                            if let e = await expand(s.text) { deliver(e, paste: true, target: target, showCount: shown) }
                        }
                        return .close
                    },
                    Action(title: "Copy") {
                        Task { @MainActor in
                            if let e = await expand(s.text) { deliver(e, paste: false, target: nil) }
                        }
                        return .close
                    },
                ],
                preview: isReference ? nil : s.text,
                historyKey: "snippet:" + s.name
            )
        }
    }
}
