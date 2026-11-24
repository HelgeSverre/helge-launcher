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
    /// `<details><summary>…</summary>…</details>`; `open` is the attribute.
    case details(summary: AttributedString, open: Bool, blocks: [MDBlock])
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
        return blockList(doc.children)
    }

    // MARK: HTML

    /// One piece of an HTML block, for folding `<details>` around the blocks between its tags.
    private enum Piece {
        case open(Bool)
        case summary(String)
        case close
        case markdown(String)
        case block(MDBlock)
    }

    private static let detailsTag = try! NSRegularExpression(
        pattern: #"<details\b([^>]*)>|</details\s*>|<summary\b[^>]*>(.*?)</summary\s*>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let anyTag = try! NSRegularExpression(
        pattern: #"<!--.*?-->|</?[A-Za-z][^>]*>"#,
        options: [.dotMatchesLineSeparators]
    )

    /// HTML without its tags and comments, entities for &, <, > and quotes decoded.
    static func stripTags(_ html: String) -> String {
        let ns = html as NSString
        var out = anyTag.stringByReplacingMatches(
            in: html,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: ""
        )
        for (e, c) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")]
        {
            out = out.replacingOccurrences(of: e, with: c)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Frame {
        var summary: AttributedString?
        var open: Bool
        var blocks: [MDBlock] = []
    }

    private static func pieces(_ html: String) -> [Piece] {
        let ns = html as NSString
        var out: [Piece] = []
        var at = 0
        func text(upTo end: Int) {
            let t = ns.substring(with: NSRange(location: at, length: end - at))
            if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.markdown(t)) }
        }
        for m in detailsTag.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            text(upTo: m.range.location)
            let tag = ns.substring(with: m.range).lowercased()
            if tag.hasPrefix("</") {
                out.append(.close)
            } else if tag.hasPrefix("<summary") {
                out.append(.summary(m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2))))
            } else {
                let attrs = m.range(at: 1).location == NSNotFound ? "" : ns.substring(with: m.range(at: 1))
                out.append(
                    .open(attrs.range(of: #"\bopen\b"#, options: [.regularExpression, .caseInsensitive]) != nil)
                )
            }
            at = m.range.location + m.range.length
        }
        text(upTo: ns.length)
        return out
    }

    /// Blocks for a run of sibling nodes. `<details>` usually spans several nodes (the opening tag, the
    /// Markdown body, the closing tag), so they are folded here rather than in `block`. An unclosed
    /// `<details>` (a streaming answer) ends with the run.
    static func blockList<S: Sequence>(_ children: S) -> [MDBlock] where S.Element == Markup {
        var ps: [Piece] = []
        for c in children {
            if let h = c as? HTMLBlock {
                let raw = h.rawHTML
                if raw.range(of: "<\\/?(details|summary)\\b", options: [.regularExpression, .caseInsensitive]) != nil {
                    ps += pieces(raw)
                } else {
                    // Other HTML: its text as Markdown, the tags dropped (comments vanish).
                    ps.append(.markdown(stripTags(raw)))
                }
            } else if let b = block(c) {
                ps.append(.block(b))
            }
        }
        var stack: [Frame] = [Frame(open: true)]
        func close() {
            let f = stack.removeLast()
            stack[stack.count - 1].blocks.append(
                .details(summary: f.summary ?? styled("Details"), open: f.open, blocks: f.blocks)
            )
        }
        for p in ps {
            switch p {
            case .open(let o): stack.append(Frame(open: o))
            case .summary(let t):
                if stack.count > 1 && stack[stack.count - 1].summary == nil {
                    stack[stack.count - 1].summary = summaryText(t)
                } else {
                    stack[stack.count - 1].blocks += blocks(stripTags(t))
                }
            case .close: if stack.count > 1 { close() }
            case .markdown(let t): stack[stack.count - 1].blocks += blocks(t)
            case .block(let b): stack[stack.count - 1].blocks.append(b)
            }
        }
        while stack.count > 1 { close() }
        return stack[0].blocks
    }

    /// The summary line: inline Markdown and HTML (`<b>`, `<code>`) reduced to styled text.
    static func summaryText(_ html: String) -> AttributedString {
        var t = html
        for (tag, md) in [("b", "**"), ("strong", "**"), ("i", "_"), ("em", "_"), ("code", "`")] {
            t = t.replacingOccurrences(
                of: "</?\(tag)\\s*>",
                with: md,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        let doc = Document(parsing: stripTags(t), options: [.disableSmartOpts])
        guard let p = doc.children.first(where: { $0 is Paragraph }) else { return styled(stripTags(t)) }
        return inlines(p)
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
                    var blocks = blockList(children)
                    if !rest.isEmpty {
                        blocks.insert(
                            .paragraph(rest.reduce(into: AttributedString()) { $0 += inline($1, Style()) }),
                            at: 0
                        )
                    }
                    return .alert(kind: kind, blocks: blocks)
                }
            }
            return .quote(blockList(children))
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
        case is HTMLBlock:
            return nil  // folded by blockList
        default:
            let text = m.format().trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : .paragraph(styled(text))
        }
    }

    static func item(_ li: ListItem) -> MDListItem {
        let checked: Bool? = li.checkbox.map { $0 == .checked }
        return MDListItem(checked: checked, blocks: blockList(li.children))
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
        case .details(let summary, _, let bs): return ([s(summary)] + bs.map(plain)).joined(separator: "\n")
        }
    }

    /// Every fenced code block, in order.
    static func codeBlocks(_ markdown: String) -> [String] {
        var out: [String] = []
        func walk(_ bs: [MDBlock]) {
            for b in bs {
                switch b {
                case .code(_, let t): out.append(t)
                case .quote(let x), .alert(_, let x), .details(_, _, let x): walk(x)
                case .list(_, _, let items): for it in items { walk(it.blocks) }
                default: break
                }
            }
        }
        walk(blocks(markdown))
        return out
    }
}
