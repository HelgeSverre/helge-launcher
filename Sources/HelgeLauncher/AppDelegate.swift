import AppKit
import Carbon
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let launcher = Launcher()
    private var panel: LauncherPanel!
    private var statusItem: NSStatusItem!
    private var watcher: ConfigWatcher?
    private var hasGoodConfig = false

    private enum MenuTag: Int {
        case configStatus = 1
        case grantAccessibility = 2
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        Task { _ = await Shell.resolvedPath() }
        panel = LauncherPanel(launcher: launcher)
        launcher.attach(panel)
        setupStatusItem()
        AppIndex.shared.scan()
        watcher = ConfigWatcher { [weak self] in self?.reloadConfig() }
        reloadConfig()
        installKeyMonitor()
        if Paths.isAppBundle { PermissionHelper.shared.requestIfNeeded() }
    }

    func applicationWillTerminate(_ n: Notification) { OpenCode.shared.stop() }

    func menuWillOpen(_ menu: NSMenu) {
        menu.item(withTag: MenuTag.grantAccessibility.rawValue)?.isHidden = PermissionHelper.shared.isTrusted
    }

    /// `helgelauncher://show[?q=]`, `clipboard`, `emoji`, `snippets`, `1password`, `ai[?q=]`.
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
                if let q { launcher.askAI(q) } else { launcher.openAIChat() }
            default:
                launcher.show(query: q)
            }
        }
    }

    // MARK: Config

    /// A broken edit keeps the previous config running and shows the error.
    @objc func reloadConfig() {
        let loaded = ConfigLoader.load()
        watcher?.reset(stamps: loaded.stamps)
        if let err = loaded.error, hasGoodConfig {
            showConfigStatus([err], keepingPrevious: true)
            return
        }
        hasGoodConfig = hasGoodConfig || loaded.error == nil
        let cfg = loaded.config ?? Config()
        launcher.apply(cfg)
        ClipboardHistory.shared.config = cfg.clipboard
        cfg.clipboard.enabled ? ClipboardHistory.shared.start() : ClipboardHistory.shared.stop()
        OnePassword.shared.config = cfg.onepassword
        OpenCode.shared.apply(cfg.ai)

        var bindings: [(String, () -> Void)] = [(cfg.hotkey, { [weak self] in self?.launcher.toggle() })]
        if let h = cfg.clipboard.hotkey {
            bindings.append((h, { [weak self] in self?.launcher.show(mode: .clipboard) }))
        }
        for c in cfg.command {
            if let h = c.hotkey { bindings.append((h, { UserCommands.run(c) })) }
        }
        let problems = [loaded.error].compactMap { $0 } + loaded.warnings + Hotkeys.shared.replace(with: bindings)

        if Paths.isAppBundle {
            let svc = SMAppService.mainApp
            if cfg.launchAtLogin, svc.status != .enabled { try? svc.register() }
            if !cfg.launchAtLogin, svc.status == .enabled { try? svc.unregister() }
        }
        showConfigStatus(problems, keepingPrevious: false)
    }

    private func showConfigStatus(_ problems: [String], keepingPrevious: Bool) {
        let text = problems.joined(separator: "; ")
        launcher.configError = problems.isEmpty ? nil : text
        statusItem.menu?.item(withTag: MenuTag.configStatus.rawValue)?.title =
            problems.isEmpty ? "Config OK" : "Config: \(text)"
        if !problems.isEmpty {
            NSLog("Helge Launcher config: %@%@", text, keepingPrevious ? " (keeping the previous config)" : "")
        }
    }

    // MARK: Keys

    /// ⌘-shortcuts the text field doesn't handle, including text editing (an accessory app has no Edit menu).
    private func installKeyMonitor() {
        let editing: [Int: Selector] = [
            kVK_ANSI_A: #selector(NSText.selectAll(_:)),
            kVK_ANSI_C: #selector(NSText.copy(_:)),
            kVK_ANSI_V: #selector(NSText.paste(_:)),
            kVK_ANSI_X: #selector(NSText.cut(_:)),
        ]
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel.isKeyWindow else { return e }
            let key = Int(e.keyCode)
            let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let l = self.launcher
            // ⌥↑ / ⌥↓: step through the chat's answers.
            if l.mode == .ai, flags.subtracting([.numericPad, .function]) == .option,
                key == kVK_UpArrow || key == kVK_DownArrow
            {
                l.moveMessage(key == kVK_UpArrow ? -1 : 1)
                return nil
            }
            guard flags.contains(.command) else { return e }
            let shift = flags.contains(.shift)
            let option = flags.contains(.option)
            let fieldHasSelection = ((self.panel.firstResponder as? NSTextView)?.selectedRange().length ?? 0) > 0
            if l.mode == .ai {
                switch key {
                case kVK_ANSI_Period:
                    l.stopOrMessageMenu()
                    return nil
                case kVK_ANSI_Y:
                    l.showConversations()
                    return nil
                case kVK_ANSI_S:
                    l.saveChatFile()
                    return nil
                case kVK_Delete where !l.conversation.turns.isEmpty && l.query.isEmpty:
                    l.deleteChat()
                    return nil
                case kVK_ANSI_R:
                    shift ? l.askAgain() : l.quote()
                    return nil
                case kVK_ANSI_C where option:
                    l.copyChat()
                    return nil
                case kVK_ANSI_C where shift:
                    l.copyCode()
                    return nil
                case kVK_ANSI_C where !fieldHasSelection && l.copySelectedMessage(): return nil
                default: break
                }
            }
            if l.mode == .chats, key == kVK_ANSI_C, !fieldHasSelection, l.copySelectedChat() { return nil }
            if l.mode != .ai, l.mode != .chats, key == kVK_ANSI_Y, l.config.ai.enabled {
                l.show()
                l.showConversations()
                return nil
            }
            switch key {
            case kVK_Return:
                self.launcher.activate(secondary: true)
            case kVK_ANSI_K:
                self.launcher.toggleActions()
            case kVK_ANSI_I:
                self.launcher.toggleSteps()
            case kVK_ANSI_N where self.launcher.mode == .ai:
                self.launcher.newChat()
            case kVK_ANSI_W:
                self.launcher.hide()
            case kVK_ANSI_Comma:
                openURL(Paths.configFile.path)
                self.launcher.hide()
            case kVK_ANSI_Z:
                let undo = (self.panel.firstResponder as? NSTextView)?.undoManager
                e.modifierFlags.contains(.shift) ? undo?.redo() : undo?.undo()
            default:
                guard let action = editing[key] else { return e }
                return NSApp.sendAction(action, to: nil, from: nil) ? nil : e
            }
            return nil
        }
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon =
            Bundle.main.image(forResource: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "command", accessibilityDescription: nil)
        icon?.isTemplate = true
        icon?.size = NSSize(width: 22, height: 22)
        icon?.accessibilityDescription = "Helge Launcher"
        statusItem.button?.image = icon

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let m = NSMenu()
        m.addItem(item("Open Helge Launcher", #selector(openPanel)))
        m.addItem(item("Version \(version)", nil))
        m.addItem(item("Edit Config…", #selector(editConfig), key: ","))
        m.addItem(item("Reload Config", #selector(reloadConfig), key: "r"))
        m.addItem(item("Config OK", nil, tag: .configStatus))
        m.addItem(item("Grant Accessibility…", #selector(grantAccessibility), tag: .grantAccessibility))
        m.addItem(.separator())
        m.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.delegate = self
        statusItem.menu = m
    }

    private func item(_ title: String, _ action: Selector?, key: String = "", tag: MenuTag? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = action == nil ? nil : self
        i.isEnabled = action != nil
        if let tag { i.tag = tag.rawValue }
        return i
    }

    @objc private func openPanel() { launcher.show() }
    @objc private func grantAccessibility() { PermissionHelper.shared.requestIfNeeded() }
    @objc private func editConfig() { openURL(Paths.configFile.path) }
}
