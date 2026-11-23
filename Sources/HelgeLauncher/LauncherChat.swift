import AppKit

/// Which chat menu is open.
enum ChatMenu: Equatable {
    /// ⌘K: the whole conversation.
    case chat
    /// ⋮ or ⌘. on one answer.
    case message(UUID)
}

/// One row of a chat menu.
struct MenuEntry {
    var title: String
    var shortcut: String?
    var destructive = false
    var separatorBefore = false
    var run: @MainActor () -> Void
}

extension Launcher {
    // MARK: Messages

    /// The answer message actions apply to: the selected one, else the last.
    var targetTurn: ChatTurn? {
        let turns = conversation.turns
        if let id = selectedTurn, let t = turns.first(where: { $0.id == id }) { return t }
        return turns.last
    }

    /// ⌥↑ / ⌥↓: steps through the answers; past the newest clears the selection.
    func moveMessage(_ d: Int) {
        guard mode == .ai, !conversation.turns.isEmpty else { return }
        chatMenu = nil
        let ids = conversation.turns.map(\.id)
        guard let current = selectedTurn, let i = ids.firstIndex(of: current) else {
            if d < 0 { selectedTurn = ids.last }
            return
        }
        let j = i + d
        selectedTurn = j >= ids.count ? nil : ids[max(0, j)]
    }

    /// ⌘.: stops an answer in progress, otherwise opens the message menu.
    func stopOrMessageMenu() {
        guard mode == .ai else { return }
        if conversation.isBusy {
            conversation.stop()
            toast("Stopped")
            return
        }
        if let t = targetTurn { openMessageMenu(t.id) }
    }

    func openMessageMenu(_ id: UUID) {
        selectedTurn = id
        actionIndex = 0
        chatMenu = chatMenu == .message(id) ? nil : .message(id)
    }

    func openChatMenu() {
        guard !conversation.turns.isEmpty else { return }
        actionIndex = 0
        chatMenu = chatMenu == .chat ? nil : .chat
    }

    var menuEntries: [MenuEntry] {
        switch chatMenu {
        case .chat: return chatEntries
        case .message(let id): return conversation.turns.first { $0.id == id }.map(messageEntries) ?? []
        case nil: return []
        }
    }

    func runMenuEntry(_ i: Int) {
        let entries = menuEntries
        chatMenu = nil
        guard entries.indices.contains(i) else { return }
        entries[i].run()
    }

    var chatEntries: [MenuEntry] {
        [
            MenuEntry(title: "Copy Last Answer", shortcut: "↵ empty") { [weak self] in self?.copyLastAnswer() },
            MenuEntry(title: "Copy Chat as Markdown", shortcut: "⌥⌘C") { [weak self] in self?.copyChat() },
            MenuEntry(title: "Save as Markdown File", shortcut: "⌘S") { [weak self] in self?.saveChatFile() },
            MenuEntry(title: "New Chat", shortcut: "⌘N") { [weak self] in self?.newChat() },
            MenuEntry(title: "Conversations", shortcut: "⌘Y") { [weak self] in self?.showConversations() },
            MenuEntry(title: "Delete Chat", shortcut: "⌘⌫", destructive: true, separatorBefore: true) { [weak self] in
                self?.deleteChat()
            },
        ]
    }

    func messageEntries(_ t: ChatTurn) -> [MenuEntry] {
        var out = [
            MenuEntry(title: "Copy as Markdown", shortcut: "⌘C") { [weak self] in self?.copy(t.answer, "Answer copied")
            },
            MenuEntry(title: "Copy as Plain Text") { [weak self] in
                self?.copy(MarkdownModel.plainText(t.answer), "Answer copied")
            },
        ]
        if !MarkdownModel.codeBlocks(t.answer).isEmpty {
            out.append(MenuEntry(title: "Copy Code", shortcut: "⇧⌘C") { [weak self] in self?.copyCode(t) })
            out.append(
                MenuEntry(title: "Paste Code into Front App", shortcut: "⌘↵") { [weak self] in self?.pasteCode(t) }
            )
        }
        out.append(
            MenuEntry(title: "Quote in Follow-up", shortcut: "⌘R", separatorBefore: true) { [weak self] in
                self?.quote(t)
            }
        )
        out.append(MenuEntry(title: "Ask Again", shortcut: "⇧⌘R") { [weak self] in self?.askAgain(t) })
        return out
    }

    // MARK: Actions

    private func copy(_ text: String, _ message: String) {
        guard !text.isEmpty else { return }
        Pasteboard.copy(text)
        toast(message)
    }

    func copyLastAnswer() {
        if let a = conversation.lastAnswer { copy(a, "Answer copied") }
    }

    /// ⌘C with nothing selected in the field: the selected answer as Markdown.
    func copySelectedMessage() -> Bool {
        guard mode == .ai, let id = selectedTurn, let t = conversation.turns.first(where: { $0.id == id }) else {
            return false
        }
        copy(t.answer, "Answer copied")
        return true
    }

    func copyChat() {
        guard !conversation.turns.isEmpty else { return }
        copy(conversation.markdown(), "Chat copied as Markdown")
    }

    func copyCode(_ t: ChatTurn? = nil) {
        guard let t = t ?? targetTurn else { return }
        let code = MarkdownModel.codeBlocks(t.answer)
        if code.isEmpty {
            toast("No code in this answer")
        } else {
            copy(code.joined(separator: "\n\n"), code.count == 1 ? "Code copied" : "\(code.count) code blocks copied")
        }
    }

    /// ⌘↵ in the chat: pastes the code of the selected (or last) answer into the app behind the panel.
    func pasteCode(_ t: ChatTurn? = nil) {
        guard let t = t ?? targetTurn else { return }
        let code = MarkdownModel.codeBlocks(t.answer)
        guard !code.isEmpty else {
            toast("No code in this answer")
            return
        }
        hide()
        Pasteboard.paste(code.joined(separator: "\n\n"))
    }

    func quote(_ t: ChatTurn? = nil) {
        guard let t = t ?? targetTurn else { return }
        let first = MarkdownModel.plainText(t.answer).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let snippet = first.count > 60 ? String(first.prefix(57)) + "…" : first
        query = "About “\(snippet)”: "
        selectedTurn = nil
        focusToken += 1
    }

    func askAgain(_ t: ChatTurn? = nil) {
        guard let t = t ?? targetTurn else { return }
        selectedTurn = nil
        conversation.sendOrQueue(t.question)
    }

    /// Writes the chat to ~/Downloads/<title>.md.
    func saveChatFile() {
        guard !conversation.turns.isEmpty else { return }
        let name = conversation.title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(
            separator: "-"
        )
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var url = dir.appendingPathComponent((name.isEmpty ? "Chat" : name) + ".md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(name) \(n).md")
            n += 1
        }
        do {
            try conversation.markdown().write(to: url, atomically: true, encoding: .utf8)
            toast("Saved to Downloads/\(url.lastPathComponent)")
        } catch {
            toast("Could not save: \(error.localizedDescription)")
        }
    }

    func deleteChat() {
        ChatStore.shared.delete(conversation.chatID)
        newChat()
        toast("Chat deleted")
    }

    // MARK: Conversations

    func showConversations() {
        guard config.ai.enabled else { return }
        chatMenu = nil
        selectedTurn = nil
        enter(.chats)
    }

    /// Saved chats, newest first, grouped by day; the query matches titles and every message.
    func chatItems() -> [Item] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let chats = ChatStore.shared.all().filter { c in
            q.isEmpty || c.title.lowercased().contains(q)
                || c.turns.contains { $0.question.lowercased().contains(q) || $0.answer.lowercased().contains(q) }
        }
        return chats.map { c in
            Item(
                id: "chat:" + c.id.uuidString,
                title: c.title,
                subtitle: Launcher.preview(c),
                accessory: Launcher.time(c.updated),
                actions: [
                    Action(title: "Continue") { [weak self] in
                        self?.continueChat(c.id)
                        return .stay
                    },
                    Action(title: "Copy as Markdown") {
                        let conv = Conversation(backend: OpenCode.shared)
                        conv.restore(c)
                        Pasteboard.copy(conv.markdown())
                        Launcher.shared?.toast("Chat copied as Markdown")
                        return .stay
                    },
                    Action(title: "Delete") {
                        ChatStore.shared.delete(c.id)
                        return .stay
                    },
                ],
                section: Launcher.section(c.updated)
            )
        }
    }

    /// ⌘C in the conversation list.
    func copySelectedChat() -> Bool {
        guard mode == .chats, let it = current, it.actions.count > 1 else { return false }
        _ = it.actions[1].run()
        return true
    }

    func continueChat(_ id: UUID) {
        guard let c = ChatStore.shared.chat(id) else { return }
        if conversation.chatID != id { conversation.restore(c) }
        mode = .ai
        setItems([], keepSelection: false)
        query = ""
        focusToken += 1
    }

    var currentChat: SavedChat? {
        guard mode == .chats, let id = current?.id, id.hasPrefix("chat:"),
            let u = UUID(uuidString: String(id.dropFirst(5)))
        else { return nil }
        return ChatStore.shared.chat(u)
    }

    static func preview(_ c: SavedChat) -> String {
        let a = c.turns.last(where: { !$0.answer.isEmpty })?.answer ?? c.turns.last?.question ?? ""
        let plain = MarkdownModel.plainText(a).replacingOccurrences(of: "\n", with: " ")
        return plain.count > 90 ? String(plain.prefix(87)) + "…" : plain
    }

    static func section(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day {
            if days < 7 { return "Last week" }
            if days < 31 { return "Last month" }
        }
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: d)
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        let cal = Calendar.current
        if cal.isDateInToday(d) || cal.isDateInYesterday(d) {
            f.dateFormat = "HH:mm"
        } else if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 {
            f.dateFormat = "EEE"
        } else {
            f.dateFormat = "d MMM"
        }
        return f.string(from: d)
    }
}
