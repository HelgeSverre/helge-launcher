import SwiftUI

/// Syntax colouring for fenced code: a single-pass scanner per language family. Approximate by design:
/// comments, strings, numbers, keywords, types, calls and keys, which is what makes code readable.
enum Highlighter {
    enum Token {
        case plain, keyword, string, number, comment, type, function, property, added, removed, meta
    }

    struct Lang {
        var keywords: Set<String> = []
        var literals: Set<String> = ["true", "false", "nil", "null", "None", "True", "False", "undefined"]
        var lineComments: [String] = []
        var blockComment: (String, String)? = nil
        var quotes: Set<Character> = ["\"", "'"]
        var tripleQuotes = false
        var capitalizedTypes = true
        var caseInsensitive = false
        var shell = false
        var keysBeforeColon = false
    }

    private static let cLike: Set<String> = [
        "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "try",
        "catch", "throw", "throws", "new", "class", "struct", "enum", "interface", "extends", "implements",
        "import", "package", "public", "private", "protected", "static", "final", "const", "var", "let", "func",
        "function", "async", "await", "in", "of", "void", "this", "self", "super", "typeof", "instanceof",
    ]

    static func lang(_ name: String) -> Lang? {
        switch name {
        case "swift":
            return Lang(
                keywords: cLike.union([
                    "guard", "defer", "where", "protocol", "extension", "init", "deinit", "inout", "some", "any",
                    "mutating", "override", "fileprivate", "internal", "open", "is", "as", "repeat", "subscript",
                    "typealias", "associatedtype", "weak", "unowned", "lazy", "indirect", "nonisolated", "actor",
                    "@MainActor", "Self",
                ]),
                lineComments: ["//"],
                blockComment: ("/*", "*/"),
                quotes: ["\""],
                tripleQuotes: true
            )
        case "js", "javascript", "jsx", "ts", "typescript", "tsx", "mjs":
            return Lang(
                keywords: cLike.union([
                    "export", "from", "type", "yield", "delete", "as", "readonly", "declare", "namespace",
                ]),
                lineComments: ["//"],
                blockComment: ("/*", "*/"),
                quotes: ["\"", "'", "`"]
            )
        case "c", "cpp", "c++", "h", "hpp", "java", "kotlin", "kt", "cs", "csharp", "dart", "scala", "zig", "php":
            return Lang(
                keywords: cLike.union([
                    "int", "char", "long", "double", "float", "bool", "unsigned", "auto", "fun", "val", "using",
                    "namespace", "template", "sizeof",
                ]),
                lineComments: ["//"],
                blockComment: ("/*", "*/")
            )
        case "go", "golang":
            return Lang(
                keywords: cLike.union(["go", "chan", "defer", "select", "map", "range", "type", "fallthrough", "goto"]),
                lineComments: ["//"],
                blockComment: ("/*", "*/"),
                quotes: ["\"", "'", "`"]
            )
        case "rust", "rs":
            return Lang(
                keywords: cLike.union([
                    "fn", "mut", "impl", "trait", "pub", "use", "mod", "crate", "match", "loop", "move", "ref", "dyn",
                    "unsafe", "where", "Self", "as",
                ]),
                lineComments: ["//"],
                blockComment: ("/*", "*/"),
                quotes: ["\""]
            )
        case "python", "py":
            return Lang(
                keywords: [
                    "def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is",
                    "import", "from", "as", "with", "try", "except", "finally", "raise", "lambda", "yield", "pass",
                    "break", "continue", "global", "nonlocal", "async", "await", "assert", "del",
                ],
                lineComments: ["#"],
                tripleQuotes: true
            )
        case "ruby", "rb":
            return Lang(
                keywords: [
                    "def", "end", "class", "module", "if", "elsif", "else", "unless", "do", "while", "return", "yield",
                    "require", "then", "begin", "rescue",
                ],
                lineComments: ["#"]
            )
        case "bash", "sh", "zsh", "shell", "console", "fish", "terminal":
            return Lang(
                keywords: [
                    "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac", "function",
                    "return", "export", "local", "set", "unset", "sudo",
                ],
                lineComments: ["#"],
                capitalizedTypes: false,
                shell: true
            )
        case "sql", "psql", "mysql", "sqlite":
            return Lang(
                keywords: [
                    "select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set",
                    "delete",
                    "create", "table", "index", "join", "left", "right", "inner", "outer", "on", "group", "by", "order",
                    "limit", "having", "as", "distinct", "count", "sum", "avg", "with", "union", "primary", "key",
                    "references", "alter", "drop", "null", "is", "in", "like", "desc", "asc", "case", "when", "then",
                    "end",
                ],
                lineComments: ["--"],
                blockComment: ("/*", "*/"),
                quotes: ["'", "\""],
                capitalizedTypes: false,
                caseInsensitive: true
            )
        case "json", "jsonc", "json5":
            return Lang(lineComments: ["//"], quotes: ["\""], capitalizedTypes: false, keysBeforeColon: true)
        case "yaml", "yml":
            return Lang(lineComments: ["#"], capitalizedTypes: false, keysBeforeColon: true)
        case "toml", "ini", "conf":
            return Lang(lineComments: ["#", ";"], capitalizedTypes: false, keysBeforeColon: true)
        case "css", "scss", "less":
            return Lang(
                lineComments: ["//"],
                blockComment: ("/*", "*/"),
                capitalizedTypes: false,
                keysBeforeColon: true
            )
        case "html", "xml", "svg", "vue", "plist":
            return Lang(blockComment: ("<!--", "-->"), capitalizedTypes: false)
        default:
            return nil
        }
    }

    static func color(_ t: Token) -> Color {
        switch t {
        case .plain: return Theme.text
        case .keyword: return Theme.synKeyword
        case .string, .added: return Theme.synString
        case .number: return Theme.synNumber
        case .comment, .meta: return Theme.muted
        case .type, .property: return Theme.synType
        case .function: return Theme.synFunction
        case .removed: return Theme.synRemoved
        }
    }

    /// The code as coloured text; unknown languages stay plain.
    static func highlight(_ code: String, language: String, size: CGFloat = 12) -> AttributedString {
        var out = AttributedString()
        for (text, token) in tokens(code, language: language) {
            var a = AttributedString(text)
            a.font = Theme.mono(size)
            a.foregroundColor = color(token)
            if token == .comment { a.font = Theme.mono(size).italic() }
            out += a
        }
        return out
    }

    static func tokens(_ code: String, language: String) -> [(String, Token)] {
        let lang = language.lowercased()
        if lang == "diff" || lang == "patch" { return diff(code) }
        if lang == "html" || lang == "xml" || lang == "svg" || lang == "vue" || lang == "plist" { return markup(code) }
        guard let spec = Highlighter.lang(lang) else { return [(code, .plain)] }
        return scan(code, spec)
    }

    // MARK: Scanners

    private static func diff(_ code: String) -> [(String, Token)] {
        code.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { i, line in
            let t: Token
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") || line.hasPrefix("diff ")
                || line.hasPrefix("index ")
            {
                t = .meta
            } else if line.hasPrefix("+") {
                t = .added
            } else if line.hasPrefix("-") {
                t = .removed
            } else {
                t = .plain
            }
            return ((i > 0 ? "\n" : "") + line, t)
        }
    }

    private static func markup(_ code: String) -> [(String, Token)] {
        var out: [(String, Token)] = []
        let c = Array(code)
        var i = 0
        var plain = ""
        func flush() {
            if !plain.isEmpty { out.append((plain, .plain)) }
            plain = ""
        }
        while i < c.count {
            if c[i] == "<" {
                if code.utf16.count > 0, i + 3 < c.count, String(c[i..<(i + 4)]) == "<!--" {
                    flush()
                    var j = i + 4
                    while j + 2 < c.count && String(c[j..<(j + 3)]) != "-->" { j += 1 }
                    j = min(c.count, j + 3)
                    out.append((String(c[i..<j]), .comment))
                    i = j
                    continue
                }
                flush()
                var j = i + 1
                while j < c.count,
                    c[j] == "/" || c[j] == "!" || c[j] == "?" || c[j].isLetter || c[j].isNumber || c[j] == "-"
                        || c[j] == ":"
                { j += 1 }
                out.append((String(c[i..<j]), .keyword))
                i = j
                // Attributes until '>'.
                while i < c.count && c[i] != ">" {
                    if c[i] == "\"" || c[i] == "'" {
                        let q = c[i]
                        var k = i + 1
                        while k < c.count && c[k] != q { k += 1 }
                        k = min(c.count, k + 1)
                        out.append((String(c[i..<k]), .string))
                        i = k
                    } else if c[i].isLetter {
                        var k = i
                        while k < c.count, c[k].isLetter || c[k] == "-" || c[k] == ":" { k += 1 }
                        out.append((String(c[i..<k]), .property))
                        i = k
                    } else {
                        out.append((String(c[i]), .plain))
                        i += 1
                    }
                }
                if i < c.count {
                    out.append((">", .keyword))
                    i += 1
                }
                continue
            }
            plain.append(c[i])
            i += 1
        }
        flush()
        return out
    }

    private static func scan(_ code: String, _ spec: Lang) -> [(String, Token)] {
        let c = Array(code)
        var out: [(String, Token)] = []
        var i = 0
        var plain = ""
        var lineStart = true
        var commandPosition = true
        func flush() {
            if !plain.isEmpty { out.append((plain, .plain)) }
            plain = ""
        }
        func starts(_ s: String, at k: Int) -> Bool {
            let p = Array(s)
            guard k + p.count <= c.count else { return false }
            return Array(c[k..<(k + p.count)]) == p
        }
        func emit(_ from: Int, _ to: Int, _ t: Token) {
            flush()
            out.append((String(c[from..<to]), t))
        }
        func nextNonSpace(_ k: Int) -> Character? {
            var j = k
            while j < c.count, c[j] == " " || c[j] == "\t" { j += 1 }
            return j < c.count ? c[j] : nil
        }
        while i < c.count {
            let ch = c[i]
            if ch == "\n" {
                plain.append(ch)
                i += 1
                lineStart = true
                commandPosition = true
                continue
            }
            // Comments
            if let lc = spec.lineComments.first(where: { starts($0, at: i) }),
                !(spec.shell && lc == "#" && i > 0 && !(c[i - 1] == " " || c[i - 1] == "\t" || c[i - 1] == "\n"))
            {
                var j = i
                while j < c.count && c[j] != "\n" { j += 1 }
                emit(i, j, .comment)
                i = j
                continue
            }
            if let (open, close) = spec.blockComment, starts(open, at: i) {
                var j = i + open.count
                while j < c.count && !starts(close, at: j) { j += 1 }
                j = min(c.count, j + close.count)
                emit(i, j, .comment)
                i = j
                continue
            }
            // Strings
            if spec.quotes.contains(ch) || (ch == "'" && spec.shell) {
                let triple = spec.tripleQuotes && starts(String(repeating: ch, count: 3), at: i)
                var j = i + (triple ? 3 : 1)
                while j < c.count {
                    if c[j] == "\\" && !(spec.shell && ch == "'") {
                        j += 2
                        continue
                    }
                    if triple {
                        if starts(String(repeating: ch, count: 3), at: j) {
                            j += 3
                            break
                        }
                    } else if c[j] == ch {
                        j += 1
                        break
                    } else if c[j] == "\n" && ch != "`" {
                        break
                    }
                    j += 1
                }
                j = min(j, c.count)
                let isKey = spec.keysBeforeColon && nextNonSpace(j) == ":"
                emit(i, j, isKey ? .property : .string)
                i = j
                lineStart = false
                commandPosition = false
                continue
            }
            // Shell variables: $HOME, ${x}
            if spec.shell && ch == "$" {
                var j = i + 1
                if j < c.count && c[j] == "{" {
                    while j < c.count && c[j] != "}" { j += 1 }
                    j = min(c.count, j + 1)
                } else {
                    while j < c.count, c[j].isLetter || c[j].isNumber || c[j] == "_" { j += 1 }
                }
                emit(i, j, .type)
                i = j
                continue
            }
            // Numbers
            if ch.isNumber, i == 0 || !(c[i - 1].isLetter || c[i - 1] == "_" || c[i - 1].isNumber) {
                var j = i
                while j < c.count, c[j].isHexDigit || c[j] == "." || c[j] == "_" || c[j] == "x" || c[j] == "e" {
                    j += 1
                }
                if j > i + 1 && c[j - 1] == "." { j -= 1 }
                emit(i, j, .number)
                i = j
                lineStart = false
                continue
            }
            // Words
            if ch.isLetter || ch == "_" || ch == "@" || (spec.shell && ch == "-" && false) {
                var j = i + 1
                while j < c.count,
                    c[j].isLetter || c[j].isNumber || c[j] == "_" || (spec.shell && (c[j] == "-" || c[j] == "."))
                { j += 1 }
                let word = String(c[i..<j])
                let key = spec.caseInsensitive ? word.lowercased() : word
                var t: Token = .plain
                if spec.keywords.contains(key) {
                    t = .keyword
                } else if spec.literals.contains(word) {
                    t = .keyword
                } else if spec.keysBeforeColon && lineStart && (nextNonSpace(j) == ":" || nextNonSpace(j) == "=") {
                    t = .property
                } else if spec.shell && commandPosition {
                    t = .function
                } else if spec.capitalizedTypes, word.first?.isUppercase == true {
                    t = .type
                } else if nextNonSpace(j) == "(" && !spec.shell {
                    t = .function
                }
                if t == .plain {
                    plain += word
                } else {
                    emit(i, j, t)
                }
                i = j
                lineStart = false
                commandPosition = false
                continue
            }
            if spec.shell && (ch == "|" || ch == ";" || ch == "&" || ch == "(") { commandPosition = true }
            if spec.keysBeforeColon, ch == "[", lineStart {
                // TOML section headers
                var j = i
                while j < c.count && c[j] != "\n" && c[j] != "]" { j += 1 }
                j = min(c.count, j + 1)
                emit(i, j, .type)
                i = j
                lineStart = false
                continue
            }
            if ch != " " && ch != "\t" { lineStart = false }
            plain.append(ch)
            i += 1
        }
        flush()
        return out
    }
}
