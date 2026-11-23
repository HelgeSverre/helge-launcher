import AppKit
import SwiftUI

final class LauncherPanel: NSPanel, NSWindowDelegate {
    init(launcher: Launcher) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Theme.panelSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isMovableByWindowBackground = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        delegate = self

        let host = NSHostingView(rootView: LauncherView().environmentObject(launcher).framedPanel())
        let fx = NSVisualEffectView.panel(containing: host)
        contentView = fx
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Centers horizontally on the screen under the mouse, upper third vertically.
    func present() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            let x = vf.midX - frame.width / 2
            let y = vf.minY + vf.height * 0.62 - frame.height / 2
            setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
        }
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }

    func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in Launcher.shared?.hide() }
    }
}

// MARK: - Search field with key handling

struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focusToken: Int
    var onCommand: (Selector) -> Bool

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = Theme.nsSans(18)
        f.textColor = NSColor(Theme.text)
        f.delegate = context.coordinator
        f.cell?.sendsActionOnEndEditing = false
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        if f.stringValue != text { f.stringValue = text }
        f.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor(Theme.muted), .font: Theme.nsSans(18),
            ]
        )
        context.coordinator.parent = self
        if context.coordinator.lastFocus != focusToken {
            context.coordinator.lastFocus = focusToken
            DispatchQueue.main.async {
                f.window?.makeFirstResponder(f)
                (f.currentEditor() as? NSTextView)?.insertionPointColor = Theme.nsAccent
                f.currentEditor()?.selectedRange = NSRange(location: (f.stringValue as NSString).length, length: 0)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        var lastFocus = -1
        init(_ p: SearchField) { parent = p }

        func controlTextDidBeginEditing(_ n: Notification) {
            (n.userInfo?["NSFieldEditor"] as? NSTextView)?.insertionPointColor = Theme.nsAccent
        }

        func controlTextDidChange(_ n: Notification) {
            if let f = n.object as? NSTextField { parent.text = f.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            parent.onCommand(sel)
        }
    }
}

// MARK: - Main view

struct LauncherView: View {
    @EnvironmentObject var l: Launcher

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 1)
            ZStack(alignment: .bottomTrailing) {
                if l.mode == .ai { ChatView(conversation: l.conversation) } else { results }
                if l.showActions, let it = l.current { ActionsMenu(item: it).padding(10) }
                if l.chatMenu == .chat { MenuView(entries: l.chatEntries).padding(10) }
            }
            .frame(maxHeight: .infinity)
            Rectangle().fill(Theme.border).frame(height: 1)
            footer
        }
        .frame(width: Theme.panelSize.width, height: Theme.panelSize.height)
        .foregroundStyle(Theme.text)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if l.mode != .root {
                Text(l.mode.title.uppercased())
                    .font(Theme.mono(11, .medium))
                    .tracking(0.6)
                    .foregroundStyle(Theme.text2)
                    .padding(.horizontal, 7).frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: Theme.radiusChip).fill(Theme.raised))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusChip).strokeBorder(Theme.borderStrong, lineWidth: 1)
                    )
            }
            SearchField(text: $l.query, placeholder: placeholder, focusToken: l.focusToken, onCommand: handle)
            if l.mode == .ai && !l.conversation.turns.isEmpty {
                Text(l.conversation.title).font(Theme.sans(12)).foregroundStyle(Theme.muted).lineLimit(1)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
            if l.mode == .ai {
                Button {
                    l.showConversations()
                } label: {
                    Image(systemName: "clock")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text2)
                        .frame(width: 30, height: 30)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radiusChip).strokeBorder(Theme.border, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Conversations")
                .help("Conversations ⌘Y")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    private var placeholder: String {
        switch l.mode {
        case .root: return "Search apps and commands…"
        case .ai:
            if l.conversation.isBusy { return "Type the next question while it answers…" }
            return l.conversation.turns.isEmpty ? "Ask anything…" : "Follow up…"
        case .chats: return "Search conversations…"
        default: return "Search \(l.mode.title)…"
        }
    }

    private func handle(_ sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveUp(_:)): l.move(-1)
        case #selector(NSResponder.moveDown(_:)): l.move(1)
        case #selector(NSResponder.insertNewline(_:)): l.activate()
        case #selector(NSResponder.cancelOperation(_:)): l.back()
        case #selector(NSResponder.insertTab(_:)): l.tab()
        case #selector(NSResponder.deleteBackward(_:)):
            if l.query.isEmpty && l.mode != .root {
                l.back()
                return true
            }
            return false
        default: return false
        }
        return true
    }

    private var results: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(l.items.enumerated()), id: \.element.id) { i, it in
                            if let s = it.section, i == 0 || l.items[i - 1].section != s {
                                Text(s)
                                    .font(Theme.sans(11, .medium))
                                    .foregroundStyle(Theme.muted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10).padding(.top, i == 0 ? 4 : 10).padding(.bottom, 2)
                            }
                            Group {
                                if l.mode == .chats {
                                    ChatRow(item: it, selected: i == l.selected)
                                } else {
                                    Row(item: it, selected: i == l.selected)
                                }
                            }
                            .id(it.id)
                            .contentShape(Rectangle())
                            .onTapGesture { l.click(i) }
                        }
                    }
                    .padding(6)
                }
                .scrollIndicators(.never)
                .onChange(of: l.selected) { _, s in
                    if l.items.indices.contains(s) { proxy.scrollTo(l.items[s].id) }
                }
            }
            .frame(width: l.mode == .chats ? 320 : nil)
            if l.mode == .chats, let chat = l.currentChat {
                Rectangle().fill(Theme.border).frame(width: 1)
                ChatPreview(chat: chat).frame(maxWidth: .infinity).background(Theme.soft)
            }
            if let p = l.current?.preview, l.mode == .clipboard || l.mode == .snippets {
                Rectangle().fill(Theme.border).frame(width: 1)
                ScrollView {
                    Text(p)
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.text2)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(16)
                }
                .frame(width: 330)
                .background(Theme.soft)
            }
        }
        .overlay {
            if l.items.isEmpty && !(l.mode == .root && l.query.isEmpty) {
                Text(l.mode == .onepassword ? "Loading 1Password…" : "No results")
                    .font(Theme.sans(13)).foregroundStyle(Theme.muted)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if let t = l.toastText {
                Text(t).foregroundStyle(Theme.text)
            } else if let e = l.configError {
                Label("Config: \(e)", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warn).lineLimit(1)
            } else if l.mode == .ai {
                ChatStatus(conversation: l.conversation, model: l.config.ai.model)
            } else if l.mode == .chats {
                Text("\(l.items.count) \(l.items.count == 1 ? "conversation" : "conversations")")
                    .font(Theme.mono(11)).foregroundStyle(Theme.muted)
            } else if !l.items.isEmpty {
                Text("\(l.items.count) \(l.items.count == 1 ? "result" : "results")")
                    .font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if l.mode == .ai {
                if l.conversation.isBusy {
                    Hint(key: "⌘.", label: "Stop")
                    Hint(key: "↵", label: "Queue")
                } else if l.selectedTurn != nil {
                    Hint(key: "⌘.", label: "Message")
                    Hint(key: "⌘K", label: "Actions")
                } else {
                    Hint(key: "↵", label: "Send")
                    Hint(key: "⌘Y", label: "Conversations")
                    if !l.conversation.turns.isEmpty { Hint(key: "⌘K", label: "Actions") }
                }
            } else if l.mode == .chats, l.current != nil {
                Hint(key: "↵", label: "Continue")
                Hint(key: "⌘C", label: "Copy as Markdown")
                Hint(key: "⌘K", label: "Actions")
            } else if let it = l.current, it.opens != nil || !it.actions.isEmpty {
                Hint(key: "↵", label: it.opens != nil ? "Open" : (it.actions.first?.title ?? ""))
                if it.calc?.steps.isEmpty == false { Hint(key: "⌘I", label: l.showSteps ? "Hide Steps" : "Steps") }
                if it.actions.count > 1 { Hint(key: "⌘K", label: "Actions") }
            }
        }
        .font(Theme.sans(12))
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Theme.soft)
    }
}

struct Hint: View {
    let key: String
    let label: String
    var body: some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(Theme.text2)
            KeyCap(key: key)
        }
    }
}

struct Row: View {
    let item: Item
    let selected: Bool

    var body: some View {
        if let card = item.calc {
            CalcCardView(card: card, selected: selected)
        } else {
            plain
        }
    }

    private var plain: some View {
        HStack(spacing: 12) {
            IconView(icon: item.icon, selected: selected).frame(width: 22, height: 22)
            Text(item.title)
                .font(Theme.sans(14, selected ? .medium : .regular))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if !item.accessory.isEmpty {
                Text(item.accessory).font(Theme.mono(11)).foregroundStyle(selected ? Theme.text2 : Theme.muted)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: Theme.radiusRow).fill(selected ? Theme.accentSoft : .clear))
    }
}

/// The calculator answer: what was understood as a caption, the answer large, details on the right.
struct CalcCardView: View {
    @EnvironmentObject var l: Launcher
    let card: CalcCard
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if card.style == .error {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.muted)
                    Text(card.answer).foregroundStyle(Theme.text2).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(Theme.sans(13))
                .frame(height: 40)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    if let e = card.expression, !(l.showSteps && !card.steps.isEmpty) {
                        Text(e)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(card.answer)
                            .font(Theme.sans(28, .semibold).monospacedDigit())
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .layoutPriority(1)
                        Spacer(minLength: 8)
                        if let d = card.detail {
                            Text(d).font(Theme.sans(12)).foregroundStyle(Theme.text2).lineLimit(1)
                        }
                    }
                }
                .frame(height: 76)
                if l.showSteps && !card.steps.isEmpty { steps }
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusRow).fill(selected ? Theme.raised : Theme.soft))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusRow)
                .strokeBorder(selected ? Theme.accentText.opacity(0.55) : Theme.border, lineWidth: 1)
        )
        .padding(.bottom, 4)
    }

    /// The chain one operation per line, running result on the right.
    private var steps: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.border).frame(height: 1).padding(.bottom, 8)
            ForEach(Array(card.steps.enumerated()), id: \.offset) { i, s in
                HStack(spacing: 12) {
                    Text(s.operation)
                        .font(Theme.mono(12))
                        .foregroundStyle(i == 0 ? Theme.text : Theme.text2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if i > 0 || s.showsResult {
                        Text(s.result)
                            .font(Theme.sans(13, i == card.steps.count - 1 ? .semibold : .regular).monospacedDigit())
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                    }
                }
                .frame(height: 22)
            }
        }
        .padding(.bottom, 10)
    }
}

@MainActor
enum IconCache {
    static var cache: [String: NSImage] = [:]
    static func image(_ path: String) -> NSImage {
        if let i = cache[path] { return i }
        let i =
            path.hasSuffix(".png")
            ? (NSImage(contentsOfFile: path) ?? NSWorkspace.shared.icon(forFile: path))
            : NSWorkspace.shared.icon(forFile: path)
        cache[path] = i
        return i
    }
}

struct IconView: View {
    let icon: ItemIcon
    var selected = false
    var body: some View {
        switch icon {
        case .file(let p): Image(nsImage: IconCache.image(p)).resizable().aspectRatio(contentMode: .fit)
        case .symbol(let s):
            Image(systemName: s)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(selected ? Theme.accentText : Theme.text2)
        case .emoji(let e): Text(e).font(.system(size: 19))
        case .none: Color.clear
        }
    }
}

struct ActionsMenu: View {
    @EnvironmentObject var l: Launcher
    let item: Item
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(item.actions.enumerated()), id: \.offset) { i, a in
                HStack {
                    Text(a.title).font(Theme.sans(13)).foregroundStyle(Theme.text)
                    Spacer()
                    if i == 0 { KeyCap(key: "↵") }
                    if i == 1 { KeyCap(key: "⌘↵") }
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusChip)
                        .fill(i == l.actionIndex ? Theme.accentSoft : .clear)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    l.actionIndex = i
                    l.activate()
                }
            }
        }
        .padding(4)
        .frame(width: 260)
        .background(RoundedRectangle(cornerRadius: Theme.radiusRow).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusRow).strokeBorder(Theme.borderStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
    }
}

/// A key combination such as "⇧⌘C": one cap per key, in the system font, which has the modifier glyphs.
struct KeyCap: View {
    let key: String
    var body: some View {
        let (keys, note) = KeyCap.split(key)
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                Text(k)
                    .font(.system(size: k.count > 1 ? 10.5 : 11.5, weight: .medium))
                    .foregroundStyle(Theme.text2)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(RoundedRectangle(cornerRadius: Theme.radiusSmall).fill(Theme.ground))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.borderStrong, lineWidth: 1)
                    )
            }
            if let note { Text(note).font(Theme.sans(11)).foregroundStyle(Theme.muted) }
        }
    }

    static let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]

    /// "⇧⌘C" → ["⇧", "⌘", "C"]; "↵ empty" → (["↵"], "empty"); "esc" → ["esc"].
    static func split(_ combo: String) -> (keys: [String], note: String?) {
        let parts = combo.split(separator: " ", maxSplits: 1).map(String.init)
        var keys: [String] = []
        var rest = Substring(parts.first ?? "")
        while let c = rest.first, modifiers.contains(c) {
            keys.append(String(c))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { keys.append(rest.count == 1 ? rest.uppercased() : String(rest)) }
        return (keys, parts.count > 1 ? parts[1] : nil)
    }
}

/// A shortcut in a menu row, spaced like macOS menus: "⇧ ⌘ C".
struct MenuShortcut: View {
    let combo: String
    var body: some View {
        let (keys, note) = KeyCap.split(combo)
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                Text(k).frame(minWidth: 11)
            }
            if let note { Text(note).font(Theme.sans(11)) }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.muted)
    }
}
