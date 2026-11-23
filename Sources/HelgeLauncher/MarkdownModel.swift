import Foundation
import Markdown
import SwiftUI

/// A rendered Markdown block. Built from swift-markdown's GitHub-flavored parse; inline text is an
/// `AttributedString` styled with the theme.
indirect enum MDBlock {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case list(ordered: Bool, start: Int, items: [MDListItem])
    case quote([MDBlock])
    case alert(kind: MDAlert, blocks: [MDBlock])
    case code(language: String, text: String)
    case table(header: [AttributedString], alignments: [HorizontalAlignment], rows: [[AttributedString]])
    case rule
    case html(String)
}

struct MDListItem {
    /// nil: not a task item.
    var checked: Bool?
    var blocks: [MDBlock]
}

enum MDAlert: String {
    case note, tip, important, warning, caution

    var title: String { rawValue.capitalized }
}

enum MarkdownModel {
    /// Blocks for `text`; safe on partial (streaming) input.
    static func blocks(_ text: String) -> [MDBlock] {
        let doc = Document(parsing: text, options: [.disableSmartOpts])
        return doc.children.compactMap(block)
    }

    // MARK: Blocks

    static func block(_ m: Markup) -> MDBlock? {
        switch m {
        case let h as Heading:
            return .heading(level: h.level, text: inlines(h))
        case let p as Paragraph:
            return .paragraph(inlines(p))
        case let l as UnorderedList:
            return .list(ordered: false, start: 1, items: l.listItems.map(item))
        case let l as OrderedList:
            return .list(ordered: true, start: Int(l.startIndex), items: l.listItems.map(item))
        case let q as BlockQuote:
            var children = Array(q.children)
            // GitHub alerts: "> [!NOTE]" as the first line (the parser splits it over several text nodes).
            if let p = children.first as? Paragraph {
                var head = ""
                var used = 0
                for c in p.children {
                    if c is SoftBreak || c is LineBreak { break }
                    guard let t = c as? Markdown.Text else {
                        head = ""
                        break
                    }
                    head += t.string
                    used += 1
                }
                let marker = head.trimmingCharacters(in: .whitespaces)
                if marker.hasPrefix("[!"), marker.hasSuffix("]"),
                    let kind = MDAlert(rawValue: String(marker.dropFirst(2).dropLast()).lowercased())
                {
                    var rest = Array(p.children.dropFirst(used))
                    while rest.first is SoftBreak || rest.first is LineBreak { rest.removeFirst() }
                    children.removeFirst()
                    var blocks = children.compactMap(block)
                    if !rest.isEmpty {
                        blocks.insert(
                            .paragraph(rest.reduce(into: AttributedString()) { $0 += inline($1, Style()) }),
                            at: 0
                        )
                    }
                    return .alert(kind: kind, blocks: blocks)
                }
            }
            return .quote(children.compactMap(block))
        case let c as CodeBlock:
            var code = c.code
            if code.hasSuffix("\n") { code.removeLast() }
            return .code(language: (c.language ?? "").lowercased(), text: code)
        case let t as Markdown.Table:
            let header = Array(t.head.cells).map { inlines($0) }
            let alignments: [HorizontalAlignment] = t.columnAlignments.map { a in
                switch a {
                case .center: return .center
                case .right: return .trailing
                default: return .leading
                }
            }
            let rows = Array(t.body.rows).map { r in Array(r.cells).map { inlines($0) } }
            return .table(header: header, alignments: alignments, rows: rows)
        case is ThematicBreak:
            return .rule
        case let h as HTMLBlock:
            return .html(h.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            let text = m.format().trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : .paragraph(styled(text))
        }
    }

    static func item(_ li: ListItem) -> MDListItem {
        let checked: Bool? = li.checkbox.map { $0 == .checked }
        return MDListItem(checked: checked, blocks: li.children.compactMap(block))
    }

    // MARK: Inline

    struct Style {
        var bold = false
        var italic = false
        var strike = false
    }

    static func styled(_ s: String, _ st: Style = Style()) -> AttributedString {
        var a = AttributedString(s)
        var font = Theme.sans(14, st.bold ? .semibold : .regular)
        if st.italic { font = font.italic() }
        a.font = font
        if st.strike {
            a.strikethroughStyle = .single
            a.foregroundColor = Theme.muted
        }
        return a
    }

    static func inlines(_ container: Markup) -> AttributedString {
        var out = AttributedString()
        for c in container.children { out += inline(c, Style()) }
        return out
    }

    static func inline(_ m: Markup, _ st: Style) -> AttributedString {
        switch m {
        case let t as Markdown.Text:
            return styled(t.string, st)
        case is SoftBreak:
            return styled(" ", st)
        case is LineBreak:
            return styled("\n", st)
        case let c as InlineCode:
            var a = AttributedString("\u{2009}" + c.code + "\u{2009}")
            a.font = Theme.mono(12.5)
            a.backgroundColor = Theme.raised
            a.foregroundColor = Theme.text
            return a
        case let e as Emphasis:
            var s = st
            s.italic = true
            return e.children.reduce(into: AttributedString()) { $0 += inline($1, s) }
        case let b as Strong:
            var s = st
            s.bold = true
            return b.children.reduce(into: AttributedString()) { $0 += inline($1, s) }
        case let d as Strikethrough:
            var s = st
            s.strike = true
            return d.children.reduce(into: AttributedString()) { $0 += inline($1, s) }
        case let l as Markdown.Link:
            var a = l.children.reduce(into: AttributedString()) { $0 += inline($1, st) }
            if a.characters.isEmpty { a = styled(l.destination ?? "", st) }
            if let d = l.destination, let url = URL(string: d) { a.link = url }
            a.foregroundColor = Theme.accentText
            a.underlineStyle = .single
            return a
        case let i as Markdown.Image:
            let alt = i.plainText.isEmpty ? "image" : i.plainText
            var a = styled("Image: " + alt, st)
            if let s = i.source, let url = URL(string: s) {
                a.link = url
                a.foregroundColor = Theme.accentText
            }
            return a
        case let h as InlineHTML:
            // <kbd>, <br>, <sup> and friends: keep the text, drop the tags.
            let raw = h.rawHTML
            if raw.lowercased().hasPrefix("<br") { return styled("\n", st) }
            return AttributedString()
        default:
            if m.childCount > 0 { return m.children.reduce(into: AttributedString()) { $0 += inline($1, st) } }
            return styled(m.format(), st)
        }
    }

    // MARK: Plain text and code

    /// Text without Markdown syntax, for "Copy as Plain Text".
    static func plainText(_ markdown: String) -> String {
        blocks(markdown).map(plain).joined(separator: "\n\n")
    }

    static func plain(_ b: MDBlock) -> String {
        func s(_ a: AttributedString) -> String { String(a.characters).replacingOccurrences(of: "\u{2009}", with: "") }
        switch b {
        case .heading(_, let t), .paragraph(let t): return s(t)
        case .list(let ordered, let start, let items):
            return items.enumerated().map { i, it in
                let mark = it.checked.map { $0 ? "[x] " : "[ ] " } ?? ""
                let bullet = ordered ? "\(start + i). " : "• "
                return bullet + mark + it.blocks.map(plain).joined(separator: "\n   ")
            }.joined(separator: "\n")
        case .quote(let bs), .alert(_, let bs): return bs.map(plain).joined(separator: "\n")
        case .code(_, let t): return t
        case .table(let h, _, let rows):
            return ([h] + rows).map { $0.map(s).joined(separator: "\t") }.joined(separator: "\n")
        case .rule: return "—"
        case .html(let t): return t
        }
    }

    /// Every fenced code block, in order.
    static func codeBlocks(_ markdown: String) -> [String] {
        var out: [String] = []
        func walk(_ bs: [MDBlock]) {
            for b in bs {
                switch b {
                case .code(_, let t): out.append(t)
                case .quote(let x), .alert(_, let x): walk(x)
                case .list(_, _, let items): for it in items { walk(it.blocks) }
                default: break
                }
            }
        }
        walk(blocks(markdown))
        return out
    }
}
