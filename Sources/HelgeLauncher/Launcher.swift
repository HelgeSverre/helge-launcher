import AppKit
import SwiftUI

struct ChatTurn: Identifiable {
    let id = UUID()
    var question: String
    var answer: String = ""
    var status: String = ""
    var done = false
}

/// Owns state for the panel: query, mode, results, AI chat.
@MainActor
final class Launcher: ObservableObject {
    static var shared: Launcher?

    @Published var query = "" { didSet { if query != oldValue { queryChanged() } } }
    @Published var mode: Mode = .root
    @Published var items: [Item] = []
    @Published var selected = 0
    @Published var showActions = false
    @Published var actionIndex = 0
    @Published var toastText: String?
    @Published var chat: [ChatTurn] = []
    @Published var configError: String?
    @Published var focusToken = 0

    var config = Config()
    private var aiSession: String?
    private var pluginTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private(set) var panel: LauncherPanel?

    init() { Launcher.shared = self }

    // MARK: Panel

    func attach(_ p: LauncherPanel) { panel = p }

    func toggle() { panel?.isVisible == true ? hide() : show() }

    func show(mode m: Mode = .root) {
        AppIndex.shared.refreshIfStale()
        if m != .root {
            enter(m)
        } else if mode != .ai {
            // The AI chat survives hide/show; everything else starts clean.
            mode = .root
            query = ""
            refresh()
        }
        panel?.present()
        focusToken += 1
    }

    func hide() {
        showActions = false
        panel?.orderOut(nil)
        if mode != .ai { mode = .root; query = "" }
    }

    func toast(_ s: String) {
        toastText = s
        toastTask?.cancel()
        toastTask = Task { try? await Task.sleep(nanoseconds: 2_500_000_000); if !Task.isCancelled { toastText = nil } }
    }

    // MARK: Items

    private var rootItems: [Item] {
        var all = AppIndex.shared.items
        if config.cleanshot.enabled { all += CleanShot.items }
        all += UserCommands.items(config.command)
        all += Snippets.items(config.snippet)
        all += config.plugin.map(Plugins.entry)
        if config.clipboard.enabled {
            all.append(Item(id: "mode.clipboard", title: "Clipboard History", icon: .symbol("doc.on.clipboard"), keywords: ["paste"], accessory: "Command", opens: .clipboard))
        }
        all.append(Item(id: "mode.emoji", title: "Search Emoji & Symbols", icon: .symbol("face.smiling"), keywords: ["emoji"], accessory: "Command", opens: .emoji))
        all.append(Item(id: "mode.snippets", title: "Search Snippets", icon: .symbol("text.quote"), accessory: "Command", opens: .snippets))
        if config.onepassword.enabled {
            all.append(Item(id: "mode.onepassword", title: "1Password", subtitle: "Search vault items", icon: .symbol("key.horizontal"), keywords: ["password", "op", "1p"], accessory: "Command", opens: .onepassword))
        }
        if config.ai.enabled {
            all.append(Item(id: "mode.ai", title: "AI Chat", subtitle: config.ai.model, icon: .symbol("sparkles"), keywords: ["ask", "ai"], accessory: "Command", opens: .ai))
        }
        all.append(Item(id: "hl.config", title: "Edit Helge Launcher Config", icon: .symbol("gearshape"), keywords: ["settings", "preferences"], accessory: "Command",
                        actions: [Action(title: "Open") { _ = openURL(Paths.configFile.path); return false }]))
        all.append(Item(id: "hl.reload", title: "Reload Helge Launcher Config", icon: .symbol("arrow.clockwise"), accessory: "Command",
                        actions: [Action(title: "Reload") { (NSApp.delegate as? AppDelegate)?.reloadConfig(); return true }]))
        return all
    }

    func computeItems() -> [Item] {
        switch mode {
        case .root:
            var r = rank(rootItems, query: query, limit: query.isEmpty ? 9 : 40)
            let q = query.trimmingCharacters(in: .whitespaces)
            if config.ai.enabled && !q.isEmpty {
                let ask = Item(id: "ai.ask", title: "Ask AI: \(q)", subtitle: config.ai.model, icon: .symbol("sparkles"), accessory: "Tab",
                               actions: [Action(title: "Ask") { self.askAI(q); return true }])
                if r.isEmpty || r[0].score < 4 { r.insert(ask, at: 0) } else { r.append(ask) }
            }
            return r
        case .clipboard:
            let all = ClipboardHistory.shared.items
            return query.isEmpty ? all : rank(all, query: query, limit: 200)
        case .emoji:
            return rank(Emoji.items, query: query, limit: 200)
        case .snippets:
            return rank(Snippets.items(config.snippet), query: query, limit: 200)
        case .onepassword:
            return rank(OnePassword.shared.items, query: query, limit: 100)
        case .plugin, .ai:
            return items
        }
    }

    func refresh() {
        items = computeItems()
        selected = 0
        showActions = false
    }

    private func queryChanged() {
        switch mode {
        case .plugin(let name):
            guard let p = config.plugin.first(where: { $0.name == name }) else { return }
            let q = query
            pluginTask?.cancel()
            pluginTask = Task {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                let r = await Plugins.query(p, q)
                guard !Task.isCancelled else { return }
                items = r
                selected = 0
            }
        case .ai:
            break
        case .root:
            // "<prefix> <query>" jumps straight into a plugin with the rest as its query.
            if let p = config.plugin.first(where: { p in p.prefix.map { query.hasPrefix($0 + " ") } ?? false }), let prefix = p.prefix {
                let rest = String(query.dropFirst(prefix.count + 1))
                mode = .plugin(p.name)
                items = []
                query = rest   // always differs from "<prefix> <rest>", so this re-runs queryChanged in plugin mode
                focusToken += 1
                return
            }
            refresh()
        default:
            refresh()
        }
    }

    func enter(_ m: Mode) {
        mode = m
        query = ""
        History.shared.record("mode.\(m)")
        switch m {
        case .onepassword:
            items = []
            Task {
                await OnePassword.shared.refresh()
                if mode == .onepassword { refresh() }
            }
            refresh()
        case .plugin:
            items = []
            queryChanged()
        case .ai:
            items = []
        default:
            refresh()
        }
        focusToken += 1
    }

    func back() {
        if showActions { showActions = false; return }
        if mode == .root {
            if query.isEmpty { hide() } else { query = "" }
        } else {
            mode = .root
            query = ""
            refresh()
        }
    }

    // MARK: Running

    var current: Item? { items.indices.contains(selected) ? items[selected] : nil }

    func move(_ d: Int) {
        if showActions {
            let n = current?.actions.count ?? 0
            if n > 0 { actionIndex = (actionIndex + d + n) % n }
            return
        }
        guard !items.isEmpty else { return }
        selected = max(0, min(items.count - 1, selected + d))
    }

    func activate(secondary: Bool = false) {
        if mode == .ai { submitAI(); return }
        guard let it = current else { return }
        if showActions {
            let i = actionIndex
            showActions = false
            if it.actions.indices.contains(i) { finish(it.actions[i].run()) }
            return
        }
        if let m = it.opens { enter(m); return }
        let idx = secondary ? 1 : 0
        guard it.actions.indices.contains(idx) else { return }
        finish(it.actions[idx].run())
    }

    private func finish(_ keepOpen: Bool) {
        if keepOpen { items = computeItems(); selected = min(selected, max(0, items.count - 1)) } else { hide() }
    }

    func toggleActions() {
        guard mode != .ai, let it = current, it.actions.count > 0 else { return }
        actionIndex = 0
        showActions.toggle()
    }

    /// Tab: send the current query to AI.
    func tab() {
        let q = query.trimmingCharacters(in: .whitespaces)
        if mode == .root, config.ai.enabled, !q.isEmpty { askAI(q) }
    }

    // MARK: AI

    func askAI(_ q: String) {
        mode = .ai
        query = ""
        items = []
        send(q)
    }

    func newChat() {
        if let s = aiSession { Task { await OpenCode.shared.interrupt(session: s) } }
        aiSession = nil
        chat = []
        query = ""
    }

    private func submitAI() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            if let last = chat.last?.answer, !last.isEmpty {
                Pasteboard.copy(last)
                toast("Answer copied")
            }
            return
        }
        query = ""
        send(q)
    }

    private func send(_ q: String) {
        chat.append(ChatTurn(question: q, status: "Thinking…"))
        let idx = chat.count - 1
        Task {
            do {
                if aiSession == nil { aiSession = try await OpenCode.shared.createSession() }
                guard let sid = aiSession else { return }
                try await OpenCode.shared.prompt(session: sid, text: q) { [weak self] ev in
                    guard let self, self.chat.indices.contains(idx) else { return }
                    switch ev {
                    case .delta(let d): self.chat[idx].answer += d; self.chat[idx].status = ""
                    case .tool(let t): self.chat[idx].status = "Using \(t)…"
                    case .done: self.chat[idx].done = true; self.chat[idx].status = ""
                    case .failed(let e): self.chat[idx].done = true; self.chat[idx].status = "Failed: \(e)"
                    }
                }
            } catch {
                if chat.indices.contains(idx) { chat[idx].status = "Error: \(error.localizedDescription)"; chat[idx].done = true }
            }
        }
    }
}
