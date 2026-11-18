import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let launcher = Launcher()
    var panel: LauncherPanel!
    var statusItem: NSStatusItem!
    var watcher: ConfigWatcher?
    var keyMonitor: Any?

    func applicationDidFinishLaunching(_ n: Notification) {
        panel = LauncherPanel(launcher: launcher)
        launcher.attach(panel)
        setupStatusItem()
        AppIndex.shared.scan()
        watcher = ConfigWatcher { [weak self] in self?.reloadConfig() }
        reloadConfig()

        // ⌘-shortcuts inside the panel that the text field doesn't see as commands.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel.isKeyWindow else { return e }
            let cmd = e.modifierFlags.contains(.command)
            switch (cmd, e.keyCode) {
            case (true, 36): self.launcher.activate(secondary: true); return nil       // ⌘↵
            case (true, 40): self.launcher.toggleActions(); return nil                 // ⌘K
            case (true, 45) where self.launcher.mode == .ai: self.launcher.newChat(); return nil // ⌘N
            case (true, 13): self.launcher.hide(); return nil                          // ⌘W
            case (true, 43): _ = openURL(Paths.configFile.path); self.launcher.hide(); return nil // ⌘,
            // Standard text editing: an accessory app has no Edit menu to route these.
            case (true, 0): return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) ? nil : e   // ⌘A
            case (true, 8): return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) ? nil : e        // ⌘C
            case (true, 9): return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) ? nil : e       // ⌘V
            case (true, 7): return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) ? nil : e         // ⌘X
            case (true, 6):                                                                                            // ⌘Z / ⇧⌘Z
                let undo = (self.panel.firstResponder as? NSTextView)?.undoManager
                e.modifierFlags.contains(.shift) ? undo?.redo() : undo?.undo()
                return nil
            default: return e
            }
        }

        // Accessibility is needed only for pasting (⌘V injection) into the frontmost app.
        permissionsChanged()
        if !AXIsProcessTrusted() && Bundle.main.bundlePath.hasSuffix(".app") { PermissionHelper.shared.start() }
    }

    func applicationWillTerminate(_ n: Notification) { OpenCode.shared.stop() }

    func permissionsChanged() {
        statusItem.menu?.item(withTag: 2)?.isHidden = AXIsProcessTrusted()
    }

    /// helgelauncher://show[?q=…] | ://clipboard | ://emoji | ://snippets | ://1password | ://ai?q=…
    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls {
            let q = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
            switch u.host ?? "" {
            case "clipboard": launcher.show(mode: .clipboard)
            case "emoji": launcher.show(mode: .emoji)
            case "snippets": launcher.show(mode: .snippets)
            case "1password": launcher.show(mode: .onepassword)
            case "ai":
                launcher.show()
                if let q { launcher.askAI(q) } else { launcher.enter(.ai) }
            default:
                launcher.show(query: q)
            }
        }
    }

    private var hasGoodConfig = false

    func reloadConfig() {
        let (cfg, err) = ConfigLoader.load()
        // A broken edit keeps the last good config running; the error shows in the footer and menu.
        if let err, hasGoodConfig {
            launcher.configError = err
            statusItem.menu?.item(withTag: 1)?.title = "Config: \(err)"
            NSLog("Helge Launcher config: %@ (keeping the previous config)", err)
            return
        }
        hasGoodConfig = hasGoodConfig || err == nil
        launcher.config = cfg
        launcher.configError = err
        ClipboardHistory.shared.config = cfg.clipboard
        cfg.clipboard.enabled ? ClipboardHistory.shared.start() : ClipboardHistory.shared.stop()
        OnePassword.shared.config = cfg.onepassword
        OpenCode.shared.apply(cfg.ai)

        var problems: [String] = err.map { [$0] } ?? []
        Hotkeys.shared.unregisterAll()
        if let e = Hotkeys.shared.register(cfg.hotkey, { [weak self] in self?.launcher.toggle() }) { problems.append(e) }
        if let h = cfg.clipboard.hotkey,
           let e = Hotkeys.shared.register(h, { [weak self] in self?.launcher.show(mode: .clipboard) }) { problems.append(e) }
        for c in cfg.command {
            guard let h = c.hotkey else { continue }
            if let e = Hotkeys.shared.register(h, { UserCommands.run(c) }) { problems.append(e) }
        }
        launcher.configError = problems.isEmpty ? nil : problems.joined(separator: "; ")

        if Bundle.main.bundlePath.hasSuffix(".app") {
            let svc = SMAppService.mainApp
            if cfg.launchAtLogin, svc.status != .enabled { try? svc.register() }
            if !cfg.launchAtLogin, svc.status == .enabled { try? svc.unregister() }
        }

        watcher?.reset(files: [Paths.configFile] + cfg.include.map { URL(fileURLWithPath: Paths.expand($0)) })
        statusItem.menu?.item(withTag: 1)?.title = problems.isEmpty ? "Config OK" : "Config: \(problems.joined(separator: "; "))"
        if !problems.isEmpty { NSLog("Helge Launcher config: %@", problems.joined(separator: "; ")) }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = Bundle.main.image(forResource: "MenuBarIcon") ?? NSImage(systemSymbolName: "command", accessibilityDescription: nil)
        icon?.isTemplate = true
        icon?.size = NSSize(width: 22, height: 22)
        icon?.accessibilityDescription = "Helge Launcher"
        statusItem.button?.image = icon
        let m = NSMenu()
        m.addItem(withTitle: "Open Helge Launcher", action: #selector(openPanel), keyEquivalent: "").target = self
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let v = NSMenuItem(title: "Version \(version)", action: nil, keyEquivalent: "")
        v.isEnabled = false
        m.addItem(v)
        m.addItem(withTitle: "Edit Config…", action: #selector(editConfig), keyEquivalent: ",").target = self
        m.addItem(withTitle: "Reload Config", action: #selector(reloadFromMenu), keyEquivalent: "r").target = self
        let status = NSMenuItem(title: "Config OK", action: nil, keyEquivalent: "")
        status.tag = 1
        status.isEnabled = false
        m.addItem(status)
        let ax = NSMenuItem(title: "Grant Accessibility…", action: #selector(grantAccessibility), keyEquivalent: "")
        ax.target = self
        ax.tag = 2
        m.addItem(ax)
        m.addItem(.separator())
        m.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = m
    }

    @objc func openPanel() { launcher.show() }
    @objc func grantAccessibility() { PermissionHelper.shared.start() }
    @objc func editConfig() { _ = openURL(Paths.configFile.path) }
    @objc func reloadFromMenu() { reloadConfig() }
}

@MainActor
func renderLauncher(_ args: [String], to path: String) {
    func arg(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    let (cfg, _) = ConfigLoader.load()
    let l = Launcher()
    l.config = cfg
    AppIndex.shared.scan()
    switch arg("--mode") ?? "root" {
    case "emoji": l.mode = .emoji
    case "snippets": l.mode = .snippets
    case "clipboard": l.mode = .clipboard
    case "ai":
        l.mode = .ai
        l.conversation = Conversation(backend: OpenCode.shared, turns: [ChatTurn(
            question: "What does `open -a` do?",
            answer: "`open -a` launches the named application (for example `open -a Safari`) and can open files or URLs with it.",
            done: true)])
    default: l.mode = .root
    }
    l.query = arg("--search") ?? ""
    if l.mode != .ai { l.items = l.computeItems() }
    if args.contains("--actions") { l.selected = 0; l.showActions = true }
    let host = NSHostingView(rootView: LauncherView().environmentObject(l)
        .background(Theme.surface)
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusPanel).strokeBorder(Theme.border, lineWidth: 1)))
    host.appearance = NSAppearance(named: args.contains("--light") ? .aqua : .darkAqua)
    host.frame = NSRect(x: 0, y: 0, width: 760, height: 480)
    let w = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    w.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

// MARK: - Headless CLI (for testing without UI)
//   HelgeLauncher --search <q> [--mode root|emoji|snippets|clipboard|onepassword]
//   HelgeLauncher --ai <question>

@MainActor
func runCLI(_ args: [String]) async -> Int32 {
    func arg(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    let (cfg, err) = ConfigLoader.load()
    if let err { print("config error: \(err)") }
    OnePassword.shared.config = cfg.onepassword

    if let text = arg("--expand") {
        guard let v = await Snippets.expand(text) else { print("error: could not expand"); return 1 }
        print(v)
        return 0
    }

    if let name = arg("--plugin") {
        guard let p = cfg.plugin.first(where: { $0.name == name }) else { print("no plugin named \(name) in config"); return 1 }
        let items = await Plugins.query(p, arg("--search") ?? "")
        for it in items {
            print("\(it.title)\(it.subtitle.isEmpty ? "" : "  — \(it.subtitle)")\(it.accessory.isEmpty ? "" : "  [\(it.accessory)]")")
            for a in it.actions { print("    · \(a.title)\(a.detail.isEmpty ? "" : ": \(a.detail)")") }
        }
        return 0
    }

    if let q = arg("--ai") {
        var ai = cfg.ai
        ai.enabled = true
        OpenCode.shared.apply(ai)
        do {
            let session = try await OpenCode.shared.createSession()
            var finished = false
            try await OpenCode.shared.prompt(session, text: q) { ev in
                switch ev {
                case .delta(let d): FileHandle.standardOutput.write(Data(d.utf8))
                case .tool(let t): FileHandle.standardError.write(Data("[tool \(t)]\n".utf8))
                case .done: finished = true
                case .failed(let e): print("\nfailed: \(e)"); finished = true
                }
            }
            let deadline = Date().addingTimeInterval(120)
            while !finished && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            print("")
            OpenCode.shared.stop()
            return finished ? 0 : 1
        } catch {
            print("ai error: \(error.localizedDescription)")
            OpenCode.shared.stop()
            return 1
        }
    }

    let l = Launcher()
    l.config = cfg
    AppIndex.shared.scan()
    switch arg("--mode") ?? "root" {
    case "emoji": l.mode = .emoji
    case "snippets": l.mode = .snippets
    case "clipboard": l.mode = .clipboard
    case "onepassword": l.mode = .onepassword; await OnePassword.shared.refresh()
    default: l.mode = .root
    }
    l.query = arg("--search") ?? ""
    let items = l.computeItems()
    print("\(items.count) results (apps indexed: \(AppIndex.shared.apps.count))")
    for it in items.prefix(Int(arg("--limit") ?? "15") ?? 15) {
        let subtitle = l.mode == .snippets ? "" : it.subtitle
        print(String(format: "%7.2f  %@  %@  %@", it.score, it.title, subtitle, it.accessory))
    }
    return 0
}

let args = CommandLine.arguments
// Debug: HelgeLauncher --render <out.png> [--mode m] [--search q] [--light] [--actions]
if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
    _ = NSApplication.shared
    await MainActor.run { renderLauncher(args, to: args[i + 1]) }
    exit(0)
}
if let i = args.firstIndex(of: "--render-helper"), i + 1 < args.count {
    _ = NSApplication.shared
    await MainActor.run { PermissionHelper.shared.renderPreview(to: args[i + 1]) }
    exit(0)
}
if ["--search", "--ai", "--mode", "--plugin", "--expand"].contains(where: args.contains) {
    let code = await runCLI(args)
    exit(code)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
