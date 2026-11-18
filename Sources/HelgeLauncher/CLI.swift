import AppKit
import SwiftUI

/// Headless entry points:
/// `--search <q> [--mode m] [--limit n]`, `--plugin <name> [--search q]`, `--expand <text>`, `--ai <question>`,
/// `--render <png> [--mode m] [--search q] [--light] [--actions]`, `--render-helper <png>`.
@MainActor
enum CLI {
    struct Arguments {
        let raw: [String]

        func value(_ name: String) -> String? {
            guard let i = raw.firstIndex(of: name), i + 1 < raw.count else { return nil }
            return raw[i + 1]
        }

        func has(_ flag: String) -> Bool { raw.contains(flag) }
    }

    static let commands = ["--search", "--ai", "--mode", "--plugin", "--expand", "--render", "--render-helper"]

    static func handles(_ args: [String]) -> Bool { commands.contains(where: args.contains) }

    static func run(_ raw: [String]) async -> Int32 {
        let args = Arguments(raw: raw)
        if let out = args.value("--render-helper") {
            _ = NSApplication.shared
            PermissionHelper.shared.renderPreview(to: out)
            return 0
        }
        let loaded = ConfigLoader.load()
        if let err = loaded.error { print("config error: \(err)") }
        let cfg = loaded.config ?? Config()
        OnePassword.shared.config = cfg.onepassword

        if let out = args.value("--render") {
            _ = NSApplication.shared
            render(cfg, args, to: out)
            return 0
        }
        if let text = args.value("--expand") { return await expand(text) }
        if let name = args.value("--plugin") { return await plugin(name, cfg, query: args.value("--search") ?? "") }
        if let q = args.value("--ai") { return await ask(q, cfg) }
        return await search(cfg, args)
    }

    private static func mode(_ name: String?) -> Mode {
        switch name {
        case "emoji": return .emoji
        case "snippets": return .snippets
        case "clipboard": return .clipboard
        case "onepassword": return .onepassword
        case "ai": return .ai
        default: return .root
        }
    }

    private static func expand(_ text: String) async -> Int32 {
        guard let e = await Snippets.expand(text) else {
            print("error: could not expand")
            return 1
        }
        print(e.text)
        return 0
    }

    private static func plugin(_ name: String, _ cfg: Config, query: String) async -> Int32 {
        guard let p = cfg.plugin.first(where: { $0.name == name }) else {
            print("no plugin named \(name) in config")
            return 1
        }
        for it in await Plugins.query(p, query) {
            let subtitle = it.subtitle.isEmpty ? "" : "  — \(it.subtitle)"
            let accessory = it.accessory.isEmpty ? "" : "  [\(it.accessory)]"
            print(it.title + subtitle + accessory)
            for a in it.actions { print("    · \(a.title)\(a.detail.isEmpty ? "" : ": \(a.detail)")") }
        }
        return 0
    }

    private static func ask(_ q: String, _ cfg: Config) async -> Int32 {
        var ai = cfg.ai
        ai.enabled = true
        OpenCode.shared.apply(ai)
        defer { OpenCode.shared.stop() }
        do {
            let session = try await OpenCode.shared.createSession()
            var finished = false
            try await OpenCode.shared.prompt(session, text: q) { ev in
                switch ev {
                case .delta(let d): FileHandle.standardOutput.write(Data(d.utf8))
                case .tool(let t): FileHandle.standardError.write(Data("[tool \(t)]\n".utf8))
                case .done: finished = true
                case .failed(let e):
                    print("\nfailed: \(e)")
                    finished = true
                }
            }
            let deadline = Date().addingTimeInterval(120)
            while !finished && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            print("")
            return finished ? 0 : 1
        } catch {
            print("ai error: \(error.localizedDescription)")
            return 1
        }
    }

    private static func search(_ cfg: Config, _ args: Arguments) async -> Int32 {
        let l = Launcher()
        l.apply(cfg)
        AppIndex.shared.scan()
        l.mode = mode(args.value("--mode"))
        if l.mode == .onepassword { await OnePassword.shared.refresh() }
        l.query = args.value("--search") ?? ""
        let items = l.computeItems()
        print("\(items.count) results (apps indexed: \(AppIndex.shared.apps.count))")
        for it in items.prefix(Int(args.value("--limit") ?? "15") ?? 15) {
            let subtitle = l.mode == .snippets ? "" : it.subtitle
            print(String(format: "%7.2f  %@  %@  %@", it.score, it.title, subtitle, it.accessory))
        }
        return 0
    }

    private static func render(_ cfg: Config, _ args: Arguments, to path: String) {
        let l = Launcher()
        l.apply(cfg)
        AppIndex.shared.scan()
        l.mode = mode(args.value("--mode"))
        if l.mode == .ai {
            l.conversation = Conversation(backend: OpenCode.shared, turns: [sampleTurn])
        }
        l.query = args.value("--search") ?? ""
        if l.mode != .ai { l.setItems(l.computeItems(), keepSelection: false) }
        if args.has("--actions") {
            l.selected = 0
            l.showActions = true
        }
        let host = NSHostingView(rootView: LauncherView().environmentObject(l).framedPanel())
        host.appearance = NSAppearance(named: args.has("--light") ? .aqua : .darkAqua)
        host.frame = NSRect(origin: .zero, size: Theme.panelSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        writePNG(host, to: path)
    }

    private static let sampleTurn = ChatTurn(
        question: "What does `open -a` do?",
        answer: "`open -a` launches the named application and can open files or URLs with it.",
        done: true
    )

    static func writePNG(_ view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
