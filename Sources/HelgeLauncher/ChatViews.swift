import SwiftUI

// MARK: - Chat

struct ChatView: View {
    @EnvironmentObject var l: Launcher
    @ObservedObject var conversation: Conversation

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if conversation.turns.isEmpty {
                        Text(l.config.ai.model).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    }
                    ForEach(conversation.turns) { t in
                        TurnView(turn: t, selected: l.selectedTurn == t.id, isLast: t.id == conversation.turns.last?.id)
                            .id(t.id)
                    }
                    if let q = conversation.queued {
                        HStack(spacing: 8) {
                            Text(q).font(Theme.sans(14, .medium)).foregroundStyle(Theme.text2)
                            Spacer(minLength: 8)
                            Text("Queued").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.radiusRow).strokeBorder(Theme.border, lineWidth: 1)
                        )
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
            .onChange(of: conversation.turns.last?.answer) { _, _ in
                if l.selectedTurn == nil { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: conversation.turns.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
                DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: l.selectedTurn) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}

struct TurnView: View {
    @EnvironmentObject var l: Launcher
    let turn: ChatTurn
    let selected: Bool
    let isLast: Bool
    @State private var hovering = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(turn.question)
                .font(Theme.sans(14, .medium))
                .foregroundStyle(Theme.text)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: Theme.radiusRow).fill(Theme.raised))
            if !turn.activities.isEmpty || !turn.done && turn.answer.isEmpty {
                ActivityView(turn: turn, expanded: $expanded)
            }
            if !turn.answer.isEmpty || turn.error != nil || turn.stopped {
                answer
            }
        }
    }

    private var answer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !turn.answer.isEmpty {
                MarkdownView(text: turn.answer, streaming: !turn.done)
            }
            if let e = turn.error {
                HStack(spacing: 8) {
                    Text("Failed: \(e)").font(Theme.sans(12.5)).foregroundStyle(Theme.err)
                    Text("Ask again").font(Theme.sans(12)).foregroundStyle(Theme.text2)
                    KeyCap(key: "⇧⌘R")
                }
            } else if turn.stopped {
                Text("Stopped").font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.trailing, 30)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusRow)
                .fill(selected || hovering ? Theme.soft : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusRow)
                .strokeBorder(selected ? Theme.accentText.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if (hovering || selected) && turn.done && !turn.answer.isEmpty {
                Button {
                    l.openMessageMenu(turn.id)
                } label: {
                    Image(systemName: "ellipsis")
                        .rotationEffect(.degrees(90))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text2)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: Theme.radiusChip).fill(Theme.raised))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radiusChip).strokeBorder(
                                Theme.borderStrong,
                                lineWidth: 1
                            )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Message actions")
                .padding(6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if l.chatMenu == .message(turn.id) {
                MenuView(entries: l.messageEntries(turn)).offset(x: -6, y: 36)
            }
        }
        .zIndex(l.chatMenu == .message(turn.id) ? 10 : 0)
        .padding(.horizontal, -8)
        .onHover { hovering = $0 }
    }
}

// MARK: - Activity

struct ActivityView: View {
    let turn: ChatTurn
    @Binding var expanded: Bool

    private var visible: [ChatActivity] {
        // Thinking only shows while nothing else is happening.
        let tools = turn.activities.filter { !$0.isThinking }
        if !turn.done, let thinking = turn.activities.last(where: { $0.isThinking && $0.state == .running }) {
            return tools + [thinking]
        }
        return tools
    }

    var body: some View {
        if turn.done {
            if !visible.isEmpty { collapsed }
        } else {
            list(live: true)
        }
    }

    private var collapsed: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "globe").font(.system(size: 11))
                    Text(ActivityView.summary(turn)).font(Theme.sans(12))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(
                        .system(size: 9, weight: .semibold)
                    )
                }
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 9).frame(height: 26)
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusChip).strokeBorder(Theme.border, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { list(live: false) }
        }
    }

    private func list(live: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            VStack(alignment: .leading, spacing: 6) {
                if visible.isEmpty {
                    row(ChatActivity(id: "wait", tool: "thinking", started: turn.started))
                }
                ForEach(visible) { a in row(a) }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusRow).strokeBorder(Theme.border, lineWidth: 1))
        }
    }

    private func row(_ a: ChatActivity) -> some View {
        HStack(spacing: 9) {
            Group {
                switch a.state {
                case .running: Spinner()
                case .done:
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted)
                case .failed:
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.err)
                }
            }
            .frame(width: 13)
            Text(ActivityView.verb(a)).foregroundStyle(Theme.text2)
            if !a.detail.isEmpty {
                Text(ActivityView.describe(a))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(ActivityView.meta(a)).font(Theme.mono(11)).foregroundStyle(Theme.muted)
        }
        .font(Theme.sans(12.5))
        .help(a.error ?? "")
    }

    static func verb(_ a: ChatActivity) -> String {
        let running = a.state == .running
        switch a.tool {
        case "thinking": return running ? "Thinking" : "Thought"
        case "websearch": return running ? "Searching" : "Searched"
        case "webfetch": return a.state == .failed ? "Could not read" : (running ? "Reading" : "Read")
        default: return running ? "Running \(a.tool)" : "Ran \(a.tool)"
        }
    }

    /// URLs as "host › path"; queries as typed.
    static func describe(_ a: ChatActivity) -> String {
        guard let u = URL(string: a.detail), let host = u.host else { return a.detail }
        let parts = [host.replacingOccurrences(of: "www.", with: "")] + u.pathComponents.filter { $0 != "/" }.prefix(3)
        return parts.joined(separator: " › ")
    }

    static func meta(_ a: ChatActivity) -> String {
        if let n = a.resultCount, a.state == .done { return n == 1 ? "1 result" : "\(n) results" }
        return seconds(a.duration)
    }

    static func seconds(_ t: TimeInterval) -> String {
        String(format: "%.1f s", t).replacingOccurrences(of: ".", with: Locale.current.decimalSeparator ?? ".")
    }

    /// "Searched 1 · read 2 pages · 6,9 s"
    static func summary(_ t: ChatTurn) -> String {
        let tools = t.activities.filter { !$0.isThinking }
        let searches = tools.filter { $0.tool == "websearch" }.count
        let reads = tools.filter { $0.tool == "webfetch" && $0.state == .done }.count
        let other = tools.filter { $0.tool != "websearch" && $0.tool != "webfetch" }.count
        var parts: [String] = []
        if searches > 0 { parts.append(searches == 1 ? "Searched once" : "Searched \(searches) times") }
        if reads > 0 { parts.append(reads == 1 ? "read 1 page" : "read \(reads) pages") }
        if other > 0 { parts.append(other == 1 ? "1 tool" : "\(other) tools") }
        var s = parts.joined(separator: " · ")
        if let f = s.first { s = f.uppercased() + s.dropFirst() }
        let total = (t.finished ?? Date()).timeIntervalSince(t.started)
        return (s.isEmpty ? "Thought" : s) + " · " + seconds(total)
    }
}

struct Spinner: View {
    @State private var on = false
    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(Theme.accentText, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 10, height: 10)
            .rotationEffect(.degrees(on ? 360 : 0))
            .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { on = true } }
    }
}

// MARK: - Markdown

struct MarkdownView: View {
    let text: String
    var streaming = false

    var body: some View {
        let blocks = MarkdownModel.blocks(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in
                BlockView(block: b, caret: streaming && i == blocks.count - 1)
            }
        }
        .textSelection(.enabled)
    }
}

struct BlockView: View {
    let block: MDBlock
    var caret = false

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(Theme.sans(level == 1 ? 18 : (level == 2 ? 16 : 14.5), .semibold))
                .foregroundStyle(level >= 3 ? Theme.text2 : Theme.text)
                .padding(.top, 4)
        case .paragraph(let text):
            Text(caret ? text + MarkdownView.caret : text)
                .font(Theme.sans(14))
                .foregroundStyle(Theme.text)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let checked = it.checked {
                            Image(systemName: checked ? "checkmark.square.fill" : "square")
                                .font(.system(size: 12))
                                .foregroundStyle(checked ? Theme.accentText : Theme.muted)
                        } else {
                            Text(ordered ? "\(start + i)." : "•")
                                .font(Theme.sans(14).monospacedDigit())
                                .foregroundStyle(Theme.muted)
                                .frame(minWidth: ordered ? 18 : 8, alignment: .trailing)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(it.blocks.enumerated()), id: \.offset) { _, b in BlockView(block: b) }
                        }
                        .opacity(it.checked == true ? 0.6 : 1)
                    }
                }
            }
        case .quote(let blocks):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in BlockView(block: b) }
            }
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.radiusRow).fill(Theme.soft))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusRow).strokeBorder(Theme.border, lineWidth: 1))
        case .alert(let kind, let blocks):
            AlertView(kind: kind, blocks: blocks)
        case .code(let language, let text):
            CodeBlockView(language: language, code: text)
        case .table(let header, let alignments, let rows):
            TableView(header: header, alignments: alignments, rows: rows)
        case .rule:
            Rectangle().fill(Theme.borderStrong).frame(height: 1).padding(.vertical, 4)
        case .html(let raw):
            Text(raw).font(Theme.mono(12)).foregroundStyle(Theme.muted)
        }
    }
}

extension MarkdownView {
    static var caret: AttributedString {
        var a = AttributedString(" ▍")
        a.foregroundColor = Theme.accentText
        return a
    }
}

struct AlertView: View {
    let kind: MDAlert
    let blocks: [MDBlock]

    var tint: Color {
        switch kind {
        case .note, .tip: return Theme.note
        case .important: return Theme.synFunction
        case .warning: return Theme.accentText
        case .caution: return Theme.err
        }
    }

    var symbol: String {
        switch kind {
        case .note: return "info.circle"
        case .tip: return "lightbulb"
        case .important: return "exclamationmark.bubble"
        case .warning: return "exclamationmark.triangle"
        case .caution: return "exclamationmark.octagon"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(kind.title, systemImage: symbol).font(Theme.sans(12.5, .semibold)).foregroundStyle(tint)
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in BlockView(block: b) }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusRow).fill(tint.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusRow).strokeBorder(tint.opacity(0.4), lineWidth: 1))
    }
}

struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "text" : language).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                Spacer()
                Button {
                    Pasteboard.copy(code)
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(Theme.sans(11.5))
                        .foregroundStyle(Theme.text2)
                        .padding(.horizontal, 7).frame(height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 12).padding(.trailing, 6)
            .frame(height: 28)
            .background(Theme.raised)
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollView(.horizontal, showsIndicators: false) {
                if language == "diff" || language == "patch" {
                    diff
                } else {
                    Text(Highlighter.highlight(code, language: language))
                        .lineSpacing(3)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                }
            }
            .background(Theme.ground)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusRow))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusRow).strokeBorder(Theme.borderStrong, lineWidth: 1))
    }

    private var diff: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(code.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) {
                _,
                line in
                let tokens = Highlighter.tokens(String(line), language: "diff")
                let t = tokens.first?.1 ?? .plain
                Text(String(line).isEmpty ? " " : String(line))
                    .font(Theme.mono(12))
                    .foregroundStyle(Highlighter.color(t))
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        t == .added ? Theme.addedBackground : (t == .removed ? Theme.removedBackground : Color.clear)
                    )
            }
        }
        .padding(.vertical, 8)
    }
}

struct TableView: View {
    let header: [AttributedString]
    let alignments: [HorizontalAlignment]
    let rows: [[AttributedString]]

    func align(_ i: Int) -> HorizontalAlignment { alignments.indices.contains(i) ? alignments[i] : .leading }
    func frameAlign(_ i: Int) -> Alignment {
        switch align(i) {
        case .center: return .center
        case .trailing: return .trailing
        default: return .leading
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { i, h in
                        cell(h, i).font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.text2)
                    }
                }
                .background(Theme.raised)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    Rectangle().fill(Theme.border).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(Array(header.indices), id: \.self) { i in
                            cell(r.indices.contains(i) ? r[i] : AttributedString(), i)
                                .font(Theme.sans(12.5).monospacedDigit())
                                .foregroundStyle(Theme.text)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusChip))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusChip).strokeBorder(Theme.borderStrong, lineWidth: 1))
        }
    }

    private func cell(_ a: AttributedString, _ i: Int) -> some View {
        var s = a
        s.font = nil
        return Text(s)
            .lineLimit(3)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(minWidth: 60, maxWidth: 280, alignment: frameAlign(i))
            .gridColumnAlignment(align(i))
    }
}

// MARK: - Menus

struct MenuView: View {
    @EnvironmentObject var l: Launcher
    let entries: [MenuEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(entries.enumerated()), id: \.offset) { i, e in
                if e.separatorBefore {
                    Rectangle().fill(Theme.borderStrong).frame(height: 1).padding(.horizontal, 6).padding(.vertical, 3)
                }
                HStack {
                    Text(e.title).font(Theme.sans(13)).foregroundStyle(e.destructive ? Theme.err : Theme.text)
                    Spacer()
                    if let s = e.shortcut { MenuShortcut(combo: s) }
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusChip).fill(
                        i == l.actionIndex ? Theme.accentSoft : .clear
                    )
                )
                .contentShape(Rectangle())
                .onTapGesture { l.runMenuEntry(i) }
            }
        }
        .padding(4)
        .frame(width: 280)
        .background(RoundedRectangle(cornerRadius: Theme.radiusRow).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusRow).strokeBorder(Theme.borderStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
    }
}

// MARK: - Conversations

struct ChatRow: View {
    let item: Item
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.title).font(Theme.sans(13.5, selected ? .medium : .regular)).foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(item.accessory).font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
            }
            Text(item.subtitle).font(Theme.sans(12)).foregroundStyle(Theme.muted).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Theme.radiusRow).fill(selected ? Theme.accentSoft : .clear))
    }
}

struct ChatPreview: View {
    let chat: SavedChat

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(chat.title).font(Theme.sans(16, .semibold)).foregroundStyle(Theme.text)
                    Text(meta).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }
                ForEach(chat.turns) { t in
                    Text(t.question)
                        .font(Theme.sans(12.5, .medium))
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: Theme.radiusChip).fill(Theme.raised))
                    Text(MarkdownModel.plainText(t.answer).prefix(400))
                        .font(Theme.sans(12.5))
                        .foregroundStyle(Theme.text2)
                        .lineSpacing(3)
                        .lineLimit(6)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var meta: String {
        let turns = chat.turns.count == 1 ? "1 turn" : "\(chat.turns.count) turns"
        let model = chat.model.split(separator: "/").last.map(String.init) ?? chat.model
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return [turns, model, f.string(from: chat.updated)].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Footer status: the model and turn count, or the time spent on the answer in progress.
struct ChatStatus: View {
    @ObservedObject var conversation: Conversation
    let model: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            Text(text).font(Theme.mono(11)).foregroundStyle(Theme.muted)
        }
    }

    private var text: String {
        let name = model.split(separator: "/").last.map(String.init) ?? model
        if let t = conversation.turns.last, !t.done {
            return "\(name) · answering \(ActivityView.seconds(Date().timeIntervalSince(t.started)))"
        }
        let n = conversation.turns.count
        return n == 0 ? name : "\(name) · \(n) \(n == 1 ? "turn" : "turns")"
    }
}
