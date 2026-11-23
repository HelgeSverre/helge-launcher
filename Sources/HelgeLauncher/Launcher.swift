import AppKit
import Calc
import SwiftUI

@MainActor
final class Launcher: ObservableObject {
    static var shared: Launcher?

    @Published var query = "" { didSet { if query != oldValue { queryChanged() } } }
    /// Leaving a mode cancels its pending plugin query.
    @Published var mode: Mode = .root {
        didSet {
            if mode != oldValue {
                pluginTask?.cancel()
                pluginTask = nil
            }
        }
    }
    @Published private(set) var items: [Item] = []
    @Published var selected = 0
    @Published var showActions = false
    /// The calculator card lists its worked steps.
    @Published var showSteps = false
    @Published var actionIndex = 0
    /// The chat's ⌘K menu or a message's ⋮ menu.
    @Published var chatMenu: ChatMenu?
    /// The message picked with ⌥↑ / ⌥↓.
    @Published var selectedTurn: UUID?
    @Published var toastText: String?
    @Published var configError: String?
    @Published var focusToken = 0
    /// Incremented by `show`.
    private(set) var showCount = 0

    var config = Config()
    var conversation: Conversation
    /// The calculator answer last copied or pasted; `ans` in the next query.
    var lastAnswer: CalcAnswer?
    private var pluginTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private(set) var panel: LauncherPanel?

    init(ai: AIBackend? = nil) {
        conversation = Conversation(backend: ai ?? OpenCode.shared)
        conversation.store = ChatStore.shared
        Launcher.shared = self
    }

    // MARK: Panel

    func attach(_ p: LauncherPanel) { panel = p }

    /// Takes a new config; an open plugin that the config no longer has returns to the root search.
    func apply(_ new: Config) {
        config = new
        conversation.model = new.ai.model
        if case .plugin(let name) = mode, !new.plugin.contains(where: { $0.name == name }) {
            mode = .root
            query = ""
            refresh()
        }
    }

    func toggle() { panel?.isVisible == true ? hide() : show() }

    /// Opens the panel; keeps the AI chat unless a mode or query is given.
    func show(mode m: Mode = .root, query q: String? = nil) {
        AppIndex.shared.refreshIfStale()
        if config.calculator.enabled { Rates.shared.refreshIfStale(enabled: config.calculator.rates) }
        if m != .root {
            enter(m)
        } else if q != nil || mode != .ai {
            mode = .root
            query = ""
            refresh()
            if let q { query = q }
        }
        showCount += 1
        panel?.present()
        focusToken += 1
    }

    func hide() {
        showActions = false
        panel?.orderOut(nil)
        if mode != .ai {
            mode = .root
            query = ""
        }
    }

    func toast(_ s: String) {
        toastText = s
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled { toastText = nil }
        }
    }

    // MARK: Items

    private var rootItems: [Item] {
        var all = AppIndex.shared.items
        if config.cleanshot.enabled { all += CleanShot.items }
        all += UserCommands.items(config.command)
        all += Snippets.items(config.snippet)
        all += Mode.entries(config)
        all.append(
            Item(
                id: "hl.config",
                title: "Edit Helge Launcher Config",
                icon: .symbol("gearshape"),
                keywords: ["settings", "preferences"],
                accessory: "Command",
                actions: [
                    Action(title: "Open") {
                        openURL(Paths.configFile.path)
                        return .close
                    }
                ]
            )
        )
        all.append(
            Item(
                id: "hl.reload",
                title: "Reload Helge Launcher Config",
                icon: .symbol("arrow.clockwise"),
                accessory: "Command",
                actions: [
                    Action(title: "Reload") {
                        (NSApp.delegate as? AppDelegate)?.reloadConfig()
                        return .stay
                    }
                ]
            )
        )
        return all
    }

    func computeItems() -> [Item] {
        switch mode {
        case .root:
            var r = rank(rootItems, query: query, limit: query.isEmpty ? 9 : 40)
            let q = query.trimmingCharacters(in: .whitespaces)
            if config.ai.enabled && !q.isEmpty {
                let ask = Item(
                    id: "ai.ask",
                    title: "Ask AI: \(q)",
                    subtitle: config.ai.model,
                    icon: .symbol("sparkles"),
                    accessory: "Tab",
                    actions: [
                        Action(title: "Ask") {
                            self.askAI(q)
                            return .stay
                        }
                    ]
                )
                if r.isEmpty || r[0].score < 4 { r.insert(ask, at: 0) } else { r.append(ask) }
            }
            if config.calculator.enabled && !q.isEmpty {
                let calc = CalcProvider.items(q, config.calculator, previous: lastAnswer) { [weak self] a in
                    self?.lastAnswer = a
                }
                // An answer replaces "Ask AI" at the top; an error row sits above everything else.
                if calc.first?.calc?.style == .result, r.first?.id == "ai.ask" { r.append(r.removeFirst()) }
                r = calc + r
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
        case .chats:
            return chatItems()
        case .plugin, .ai:
            return items
        }
    }

    func refresh() { setItems(computeItems(), keepSelection: false) }

    /// `keepSelection` keeps the selected id when it is still listed, else the first item is selected.
    /// ⌘K closes when the selected item changes. Duplicate ids get a `#n` suffix.
    func setItems(_ new: [Item], keepSelection: Bool) {
        let previous = current?.id
        var used = Set<String>()
        items = new.map { item in
            var item = item
            let base = item.id
            var n = 1
            while used.contains(item.id) {
                item.id = "\(base)#\(n)"
                n += 1
            }
            used.insert(item.id)
            return item
        }
        if keepSelection, let previous, let i = items.firstIndex(where: { $0.id == previous }) {
            selected = i
        } else if keepSelection {
            selected = min(selected, max(0, items.count - 1))
        } else {
            // A row with nothing to run (a calculator error) is not selected first.
            selected = items.firstIndex { $0.opens != nil || !$0.actions.isEmpty || $0.calc == nil } ?? 0
        }
        if current?.id != previous { showActions = false }
    }

    /// ⌘I: shows or hides the worked steps of the selected calculator answer.
    func toggleSteps() {
        guard current?.calc?.steps.isEmpty == false else { return }
        showActions = false
        showSteps.toggle()
    }

    private func queryChanged() {
        showSteps = false
        switch mode {
        case .plugin(let name):
            guard let p = config.plugin.first(where: { $0.name == name }) else { return }
            let q = query
            pluginTask?.cancel()
            pluginTask = Task {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                let r = await Plugins.query(p, q)
                guard !Task.isCancelled, mode == .plugin(name) else { return }
                setItems(r, keepSelection: false)
            }
        case .ai:
            break
        case .root:
            if let p = config.plugin.first(where: { p in p.prefix.map { query.hasPrefix($0 + " ") } ?? false }),
                let prefix = p.prefix
            {
                enter(.plugin(p.name), query: String(query.dropFirst(prefix.count + 1)))
                return
            }
            refresh()
        default:
            refresh()
        }
    }

    func enter(_ m: Mode, query q: String = "") {
        History.shared.record(m.itemID)
        mode = m
        setItems([], keepSelection: false)
        let unchanged = query == q
        query = q
        switch m {
        case .onepassword:
            Task {
                await OnePassword.shared.refresh()
                if mode == .onepassword { setItems(computeItems(), keepSelection: true) }
            }
            refresh()
        case .plugin:
            if unchanged { queryChanged() }
        case .ai:
            break
        default:
            refresh()
        }
        focusToken += 1
    }

    func back() {
        if chatMenu != nil {
            chatMenu = nil
            return
        }
        if mode == .ai, selectedTurn != nil {
            selectedTurn = nil
            return
        }
        if mode == .chats {
            enter(.ai)
            return
        }
        if showActions {
            showActions = false
            return
        }
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
        if chatMenu != nil {
            let n = menuEntries.count
            if n > 0 { actionIndex = (actionIndex + d + n) % n }
            return
        }
        if showActions {
            let n = current?.actions.count ?? 0
            if n > 0 { actionIndex = (actionIndex + d + n) % n }
            return
        }
        guard !items.isEmpty else { return }
        selected = max(0, min(items.count - 1, selected + d))
    }

    func activate(secondary: Bool = false) {
        if chatMenu != nil {
            runMenuEntry(actionIndex)
            return
        }
        if mode == .ai {
            if secondary {
                pasteCode()
            } else {
                submitAI()
            }
            return
        }
        guard let it = current else { return }
        if showActions {
            showActions = false
            run(it, action: actionIndex)
            return
        }
        if let m = it.opens {
            enter(m)
            return
        }
        run(it, action: secondary ? 1 : 0)
    }

    private func run(_ it: Item, action index: Int) {
        guard it.actions.indices.contains(index) else { return }
        if let key = it.historyKey { History.shared.record(key) }
        finish(it.actions[index].run())
    }

    func click(_ index: Int) {
        showActions = false
        selected = index
        activate()
    }

    private func finish(_ outcome: Action.Outcome) {
        switch outcome {
        case .stay: setItems(computeItems(), keepSelection: true)
        case .close: hide()
        }
    }

    func toggleActions() {
        if mode == .ai {
            openChatMenu()
            return
        }
        guard let it = current, it.actions.count > 0 else { return }
        actionIndex = 0
        showActions.toggle()
    }

    func tab() {
        let q = query.trimmingCharacters(in: .whitespaces)
        if mode == .root, config.ai.enabled, !q.isEmpty { askAI(q) }
    }

    // MARK: AI

    /// A draft (non-empty chat field that isn't `q`) is never cleared or replaced. While busy, `q`
    /// stays in the field unless that would replace a draft.
    func askAI(_ q: String) {
        guard config.ai.enabled else {
            toast("AI is disabled in the config")
            return
        }
        guard !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            openAIChat()
            return
        }
        let inField = query.trimmingCharacters(in: .whitespaces) == q
        let hasDraft = mode == .ai && !query.isEmpty && !inField
        if conversation.isBusy {
            if !inField && !hasDraft {
                mode = .ai
                setItems([], keepSelection: false)
                query = q
            }
            toast("Still answering · ⌘N for a new chat")
            return
        }
        mode = .ai
        setItems([], keepSelection: false)
        conversation.send(q)
        if !hasDraft { query = "" }
    }

    func openAIChat() {
        guard config.ai.enabled else {
            toast("AI is disabled in the config")
            return
        }
        if mode != .ai { enter(.ai) }
    }

    func newChat() {
        conversation.reset()
        query = ""
        selectedTurn = nil
        chatMenu = nil
    }

    private func submitAI() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            if let last = conversation.lastAnswer {
                Pasteboard.copy(last)
                toast("Answer copied")
            }
            return
        }
        submit(q)
    }

    /// While an answer streams, the question waits and is sent after it.
    private func submit(_ q: String) {
        conversation.sendOrQueue(q)
        query = ""
        selectedTurn = nil
    }
}
