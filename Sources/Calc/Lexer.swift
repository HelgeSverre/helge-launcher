import Foundation

struct DateLit: Equatable {
    var year: Int?
    var month: Int
    var day: Int
    var hour: Int? = nil
    var minute: Int? = nil
    var second: Int? = nil
}

struct ClockLit: Equatable {
    var h: Int
    var m: Int
    var s: Int?
    /// Colon groups written: 1 for "5pm" / "kl 14", 2 for "9:30", 3 for "1:30:00".
    var parts: Int
}

/// A named zone. `fixed` zones ("EST") keep their offset all year.
struct ZoneLit {
    var zone: TimeZone
    /// Which reading this is ("New York time").
    var label: String
    /// As written, for the interpretation ("EST").
    var short: String? = nil
}

indirect enum Tok {
    case num(Num, radix: Int)
    case unit(UnitDef)
    case scale(Num, String)
    case op(String)
    case ident(String)
    case date(DateLit)
    case clock(ClockLit)
    case zone(ZoneLit)
    case kw(String)
    case radixTarget(Int)
    case dateWord(String)
    case choice([Alt], offer: Bool)
}

struct Alt {
    var toks: [Token]
    var label: String?
}

struct Token {
    var tok: Tok
    var space: Bool

    init(_ t: Tok, space: Bool = true) {
        tok = t
        self.space = space
    }

    var isNumber: Bool {
        if case .num = tok { return true }
        return false
    }
    var opText: String? {
        if case .op(let s) = tok { return s }
        return nil
    }
    var kwText: String? {
        if case .kw(let s) = tok { return s }
        return nil
    }
    var unit: UnitDef? {
        if case .unit(let u) = tok { return u }
        return nil
    }
}

/// Stops the whole query: nil result (no row), or a visible error.
struct LexFailure: Error {
    var message: String?
}

// MARK: - Raw scanning

enum Raw {
    case number(String, radix: Int, options: [(String, String?)], offer: Bool, inCall: Bool)
    case word(String)
    case sym(String)
    case clock(ClockLit)
    case date(DateLit)
    case slashDate(Int, Int, Int)
}

struct RawTok {
    var raw: Raw
    var space: Bool
}

enum Lexer {
    static func tokenize(_ input: String, locale: CalcLocale) throws -> [Token] {
        let raws = try scan(input, locale: locale)
        var r = Resolver(raws: raws, locale: locale)
        return try r.run()
    }

    // MARK: Text normalization

    static func normalize(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "\u{FF10}"..."\u{FF19}":
                out.append(Character(UnicodeScalar(ch.unicodeScalars.first!.value - 0xFF10 + 48)!))
            case "＋": out.append("+")
            case "－", "−", "–", "—": out.append("-")
            case "×", "✕", "⋅", "·", "＊": out.append("*")
            case "÷", "∕", "／", "⁄": out.append("/")
            case "\u{00A0}", "\u{202F}", "\u{2009}", "\u{2007}", "\t", "\n": out.append(" ")
            case "²": out.append("^2")
            case "³": out.append("^3")
            case "½": out.append(" 1/2")
            case "¼": out.append(" 1/4")
            case "¾": out.append(" 3/4")
            case "⅓": out.append(" 1/3")
            case "⅔": out.append(" 2/3")
            case "⅛": out.append(" 1/8")
            case "√": out.append(" sqrt ")
            case "π": out.append(" pi ")
            case "’", "′": out.append("'")
            case "″", "“", "”": out.append("\"")
            case "→": out.append(" to ")
            default: out.append(ch)
            }
        }
        out = out.replacingOccurrences(of: "**", with: "^")
        out = out.replacingOccurrences(of: "->", with: " to ")
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        out = out.trimmingCharacters(in: .whitespaces)
        if out.hasPrefix("=") && !out.hasPrefix("==") {
            out = String(out.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if out.hasSuffix("=") && !out.hasSuffix("==") {
            out = String(out.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if out.hasSuffix("?") { out = String(out.dropLast()).trimmingCharacters(in: .whitespaces) }
        return out
    }

    // MARK: Scanner

    private static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c == "°" || c == "µ" || c == "Ω" || c == "Å" || c == "₿"
    }

    private static func scan(_ s: String, locale: CalcLocale) throws -> [RawTok] {
        let c = Array(s)
        var i = 0
        var out: [RawTok] = []
        var space = true
        /// Paren stack: true when the paren opens a function call.
        var parens: [Bool] = []

        func at(_ k: Int) -> Character? { k < c.count ? c[k] : nil }
        func isDigit(_ k: Int) -> Bool { at(k)?.isASCII == true && at(k)!.isNumber }
        func digits(from k: Int) -> Int {
            var j = k
            while isDigit(j) { j += 1 }
            return j - k
        }
        func int(_ a: Int, _ len: Int) -> Int { Int(String(c[a..<(a + len)]))! }
        func emit(_ r: Raw) {
            out.append(RawTok(raw: r, space: space))
            space = false
        }

        while i < c.count {
            let ch = c[i]
            if ch == " " {
                space = true
                i += 1
                continue
            }
            if isDigit(i) || (ch == "." && isDigit(i + 1)) {
                // ISO date, optionally with a time.
                if digits(from: i) == 4, at(i + 4) == "-", digits(from: i + 5) >= 1, digits(from: i + 5) <= 2 {
                    let mlen = digits(from: i + 5)
                    let dpos = i + 5 + mlen
                    if at(dpos) == "-", (1...2).contains(digits(from: dpos + 1)) {
                        let dlen = digits(from: dpos + 1)
                        var lit = DateLit(year: int(i, 4), month: int(i + 5, mlen), day: int(dpos + 1, dlen))
                        var j = dpos + 1 + dlen
                        if at(j) == " " || at(j) == "T", (1...2).contains(digits(from: j + 1)) {
                            let hl = digits(from: j + 1)
                            if at(j + 1 + hl) == ":", digits(from: j + 2 + hl) == 2 {
                                lit.hour = int(j + 1, hl)
                                lit.minute = int(j + 2 + hl, 2)
                                j = j + 4 + hl
                                if at(j) == ":", digits(from: j + 1) == 2 {
                                    lit.second = int(j + 1, 2)
                                    j += 3
                                }
                            }
                        }
                        emit(.date(lit))
                        i = j
                        continue
                    }
                }
                // Dotted (23.11.2026) and slashed (01/02/2026) dates.
                let l1 = digits(from: i)
                if (1...2).contains(l1), at(i + l1) == "." || at(i + l1) == "/" {
                    let sep = at(i + l1)!
                    let l2 = digits(from: i + l1 + 1)
                    if (1...2).contains(l2), at(i + l1 + 1 + l2) == sep, digits(from: i + l1 + 2 + l2) == 4 {
                        let a = int(i, l1)
                        let b = int(i + l1 + 1, l2)
                        let y = int(i + l1 + 2 + l2, 4)
                        emit(sep == "." ? .date(DateLit(year: y, month: b, day: a)) : .slashDate(a, b, y))
                        i += l1 + l2 + 6
                        continue
                    }
                }
                // Clock: 9:30, 17:15, 1:30:00, 45:00
                if (1...2).contains(l1), at(i + l1) == ":", digits(from: i + l1 + 1) == 2 {
                    var lit = ClockLit(h: int(i, l1), m: int(i + l1 + 1, 2), s: nil, parts: 2)
                    var j = i + l1 + 3
                    if at(j) == ":", digits(from: j + 1) == 2 {
                        lit.s = int(j + 1, 2)
                        lit.parts = 3
                        j += 3
                    }
                    if isDigit(j) || at(j) == ":" { throw LexFailure() }
                    emit(.clock(lit))
                    i = j
                    continue
                }
                // Radix literals.
                if ch == "0", let p = at(i + 1), "xXbBoO".contains(p) {
                    let radix = "xX".contains(p) ? 16 : ("bB".contains(p) ? 2 : 8)
                    var j = i + 2
                    while let d = at(j), d == "_" || (d.hexDigitValue.map { $0 < radix } ?? false) { j += 1 }
                    if j == i + 2 { throw LexFailure() }
                    if let d = at(j), d.isLetter || d.isNumber { throw LexFailure() }
                    emit(.number(String(c[(i + 2)..<j]), radix: radix, options: [], offer: false, inCall: false))
                    i = j
                    continue
                }
                let (text, end) = scanDecimal(c, i)
                let inCall = parens.last == true
                let (options, offer) = try interpret(text, locale: locale, inCall: inCall)
                emit(.number(text, radix: 10, options: options, offer: offer, inCall: inCall))
                i = end
                // Exponent marker with nothing after it ("1e").
                if at(i) == "e" || at(i) == "E", !(at(i + 1)?.isLetter ?? false) { throw LexFailure() }
                continue
            }
            if ch == "x" || ch == "X", !space, let last = out.last, case .number = last.raw, isDigit(i + 1) {
                emit(.sym("*"))
                i += 1
                continue
            }
            if isWordChar(ch) {
                var j = i
                while let d = at(j), isWordChar(d) || (d == "'" && (at(j + 1)?.isLetter ?? false) && j > i) { j += 1 }
                // Identifier with digits (mp3, log2, m2, k8s).
                while let d = at(j), d.isLetter || d.isNumber || d == "_" { j += 1 }
                emit(.word(String(c[i..<j])))
                i = j
                continue
            }
            // Symbols.
            let two = i + 1 < c.count ? String(c[i...(i + 1)]) : ""
            if ["//", "<<", ">>", "==", "!=", "<=", ">=", ",-"].contains(two) {
                if two == ",-" {
                    emit(.word(",-"))
                } else {
                    emit(.sym(two))
                }
                i += 2
                continue
            }
            switch ch {
            case "(":
                let call: Bool = {
                    guard let last = out.last, !space else { return false }
                    if case .word = last.raw { return true }
                    return false
                }()
                parens.append(call)
                emit(.sym("("))
            case ")":
                _ = parens.popLast()
                emit(.sym(")"))
            case "$", "€", "£", "¥", "₹", "¢", "'", "\"", "%", "‰":
                emit(.word(String(ch)))
            case "+", "-", "*", "/", "^", ",", ";", "=", "!", "&", "|", "~", ".", ":", "<", ">":
                emit(.sym(String(ch)))
            default:
                throw LexFailure()
            }
            i += 1
        }
        return out
    }

    /// A run of digits with grouping and decimal marks; spaces join only before 3-digit groups.
    private static func scanDecimal(_ c: [Character], _ start: Int) -> (String, Int) {
        var i = start
        var text = ""
        func isDigit(_ k: Int) -> Bool { k < c.count && c[k].isASCII && c[k].isNumber }
        func groupOf3(_ k: Int) -> Bool { isDigit(k) && isDigit(k + 1) && isDigit(k + 2) && !isDigit(k + 3) }
        while i < c.count {
            let ch = c[i]
            if ch.isASCII && ch.isNumber {
                text.append(ch)
                i += 1
            } else if (ch == "," || ch == ".") && isDigit(i + 1) {
                text.append(ch)
                i += 1
            } else if (ch == "'" || ch == "_") && groupOf3(i + 1) && !text.isEmpty {
                text.append("_")
                i += 1
            } else if ch == " " && groupOf3(i + 1) && !text.contains(",") && !text.contains(".") {
                // "1 000 000": every group so far must be digits only, the first 1-3 long.
                let groups = text.split(separator: "_")
                if let first = groups.first, first.count <= 3, text.allSatisfy({ $0.isNumber || $0 == "_" }) {
                    text.append("_")
                    i += 1
                } else {
                    break
                }
            } else if ch == "e" || ch == "E", !text.isEmpty,
                isDigit(i + 1) || ((c.count > i + 2) && (c[i + 1] == "-" || c[i + 1] == "+") && isDigit(i + 2))
            {
                text.append("e")
                i += 1
                if c[i] == "-" || c[i] == "+" {
                    text.append(c[i])
                    i += 1
                }
                while isDigit(i) {
                    text.append(c[i])
                    i += 1
                }
                break
            } else {
                break
            }
        }
        return (text, i)
    }

    /// Readings of a written number as canonical decimals ("1234.5"), first is preferred.
    private static func interpret(
        _ raw: String,
        locale: CalcLocale,
        inCall: Bool
    ) throws -> ([(String, String?)], Bool) {
        var exp = ""
        var body = raw
        if let e = raw.firstIndex(of: "e") {
            exp = String(raw[e...])
            body = String(raw[..<e])
        }
        let spaced = body.replacingOccurrences(of: "_", with: "")
        let commas = spaced.filter { $0 == "," }.count
        let dots = spaced.filter { $0 == "." }.count
        func groupsValid(_ s: String, sep: Character) -> Bool {
            let parts = s.split(separator: sep, omittingEmptySubsequences: false)
            guard let first = parts.first, (1...3).contains(first.count) else { return false }
            return parts.dropFirst().allSatisfy { $0.count == 3 }
        }
        func strip(_ s: String, _ ch: Character) -> String { s.filter { $0 != ch } }
        if body.contains("_") {
            // Grouped with spaces, apostrophes or underscores; groups must be valid.
            let intPart = String(body.split(separator: ",").first ?? "")
            guard groupsValid(intPart.replacingOccurrences(of: ".", with: ""), sep: "_") || !body.contains(" ") else {
                throw LexFailure()
            }
            var s = spaced
            if commas == 1 && dots == 0 { s = s.replacingOccurrences(of: ",", with: ".") }
            return ([(s + exp, nil)], false)
        }
        switch (commas, dots) {
        case (0, 0), (0, 1):
            return ([(spaced + exp, nil)], false)
        case (0, _):
            if groupsValid(spaced, sep: ".") && locale.decimalMark == "," {
                return ([(strip(spaced, ".") + exp, nil)], false)
            }
            throw LexFailure()
        case (1, 0):
            let parts = spaced.split(separator: ",")
            let a = String(parts[0])
            let b = String(parts[1])
            let decimal = a + "." + b
            let joined = a + b
            if inCall {
                // max(1,5): argument separator first.
                return (
                    [("SPLIT:\(a):\(b)", locale.decimalMark == "," ? "max of \(a) and \(b)" : nil), (decimal, nil)],
                    locale.decimalMark == ","
                )
            }
            if b.count == 3 && a.count <= 3 {
                if locale.decimalMark == "," {
                    return (
                        [(decimal + exp, "\(raw) = \(a) (decimal comma)"), (joined + exp, "\(raw) = \(joined)")], true
                    )
                }
                return ([(joined + exp, nil)], false)
            }
            return ([(decimal + exp, nil)], false)
        case (_, 0):
            if groupsValid(spaced, sep: ",") && locale.decimalMark == "." {
                return ([(strip(spaced, ",") + exp, nil)], false)
            }
            if groupsValid(spaced, sep: ",") { return ([(strip(spaced, ",") + exp, nil)], false) }
            throw LexFailure(
                message: locale.nb
                    ? "\(raw) er ikke et tall: to desimalkomma" : "\(raw) is not a number: two decimal commas"
            )
        default:
            // Both marks: the last one is the decimal mark.
            let lastComma = spaced.lastIndex(of: ",")!
            let lastDot = spaced.lastIndex(of: ".")!
            let (group, dec): (Character, Character) = lastComma > lastDot ? (".", ",") : (",", ".")
            let parts = spaced.split(separator: dec)
            guard parts.count == 2, groupsValid(String(parts[0]), sep: group) else { throw LexFailure() }
            return ([(strip(String(parts[0]), group) + "." + parts[1] + exp, nil)], false)
        }
    }
}

// MARK: - Resolver: raw tokens to classified tokens

struct Resolver {
    let raws: [RawTok]
    let locale: CalcLocale
    var out: [Token] = []
    var i = 0

    init(raws: [RawTok], locale: CalcLocale) {
        self.raws = raws
        self.locale = locale
    }

    static let monthNames: [String: Int] = {
        var m: [String: Int] = [:]
        let en = [
            "january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
            "november", "december",
        ]
        let nb = [
            "januar", "februar", "mars", "april", "mai", "juni", "juli", "august", "september", "oktober", "november",
            "desember",
        ]
        for (i, n) in en.enumerated() {
            m[n] = i + 1
            m[String(n.prefix(3))] = i + 1
        }
        for (i, n) in nb.enumerated() {
            m[n] = i + 1
            m[String(n.prefix(3))] = i + 1
        }
        m["sept"] = 9
        m["okt"] = 10
        m["des"] = 12
        return m
    }()

    static let numberWordsEn: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    static let numberWordsNb: [String: Int] = [
        "null": 0, "en": 1, "ett": 1, "ei": 1, "et": 1, "to": 2, "tre": 3, "fire": 4, "fem": 5, "seks": 6, "sju": 7,
        "syv": 7, "åtte": 8, "ni": 9, "ti": 10, "elleve": 11, "tolv": 12, "tretten": 13, "fjorten": 14, "femten": 15,
        "seksten": 16, "sytten": 17, "atten": 18, "nitten": 19, "tjue": 20, "tyve": 20, "tretti": 30, "tredve": 30,
        "førti": 40, "femti": 50, "seksti": 60, "sytti": 70, "åtti": 80, "nitti": 90,
    ]
    static let fractionWords: [String: Int] = [
        "half": 2, "halves": 2, "third": 3, "thirds": 3, "quarter": 4, "quarters": 4, "fourth": 4, "fourths": 4,
        "fifth": 5, "fifths": 5, "sixth": 6, "sixths": 6, "eighth": 8, "eighths": 8, "tenth": 10, "tenths": 10,
    ]

    static let keywords: Set<String> = [
        "in", "into", "to", "as", "at", "per", "for", "of", "and", "on", "ago", "each", "from", "by", "between",
        "until", "till", "since", "is", "than", "with",
    ]
    static let functions: Set<String> = [
        "sqrt", "cbrt", "sin", "cos", "tan", "asin", "acos", "atan", "arcsin", "arccos", "arctan", "sinh", "cosh",
        "tanh", "ln", "log", "log10", "log2", "exp", "abs", "round", "floor", "ceil", "trunc", "max", "min", "gcd",
        "lcm", "sum", "avg", "average", "mean", "product", "fact", "factorial", "rgb", "root",
    ]
    static let constants: Set<String> = ["pi", "e", "tau", "phi", "ans", "speedoflight"]

    func scale(_ w: String) -> (Num, String)? {
        switch w {
        case "thousand", "thousands", "tusen", "k": return (Num(1000), w)
        case "million", "millions", "mill", "mio", "millioner", "millionen", "mln": return (Num(1_000_000), "million")
        case "milliard", "milliarder", "mrd", "bn": return (Num(1_000_000_000), "milliard")
        case "billion", "billions", "billioner":
            return locale.nb ? (Num(decimal: "1e12")!, "billion") : (Num(1_000_000_000), "billion")
        case "trillion", "trillions": return (Num(decimal: "1e12")!, "trillion")
        case "dozen", "dozens", "dusin": return (Num(12), "dozen")
        case "gross": return (Num(144), "gross")
        case "score": return (Num(20), "score")
        default: return nil
        }
    }

    // MARK: Helpers

    func raw(_ k: Int) -> RawTok? { k >= 0 && k < raws.count ? raws[k] : nil }
    func word(_ k: Int) -> String? {
        if let r = raw(k), case .word(let w) = r.raw { return w }
        return nil
    }
    func sym(_ k: Int) -> String? {
        if let r = raw(k), case .sym(let s) = r.raw { return s }
        return nil
    }
    func isNumber(_ k: Int) -> Bool {
        if let r = raw(k), case .number = r.raw { return true }
        return false
    }
    /// Words k..<k+n joined by spaces, when no symbol sits between them.
    func phrase(_ k: Int, _ n: Int) -> String? {
        var parts: [String] = []
        for j in k..<(k + n) {
            guard let w = word(j) else { return nil }
            if j > k && !(raw(j)?.space ?? false) { return nil }
            parts.append(w)
        }
        return parts.joined(separator: " ")
    }

    var lastTok: Token? { out.last }
    var lastEndsQuantity: Bool {
        guard let t = lastTok else { return false }
        switch t.tok {
        case .unit, .num, .scale: return true
        case .choice(let alts, _):
            if let f = alts.first?.toks.last { return Token(f.tok).unit != nil || f.isNumber }
            return false
        default: return false
        }
    }
    var lastIsNumberish: Bool {
        guard let t = lastTok else { return false }
        if case .num = t.tok {
            // An exponent ("m^2") or a prefixed amount ("$100") already ends a quantity.
            if out.count >= 2 {
                let before = out[out.count - 2]
                if before.opText == "^" { return false }
                if let u = before.unit, u.dim == .money { return false }
                if case .choice(let alts, _) = before.tok, alts.first?.toks.first?.unit?.dim == .money { return false }
            }
            return true
        }
        if case .scale = t.tok { return true }
        if case .choice(let alts, _) = t.tok, alts.first?.toks.last?.isNumber == true { return true }
        return false
    }

    mutating func push(_ t: Tok, space: Bool) { out.append(Token(t, space: space)) }

    func unitChoice(_ c: Choices, space: Bool) -> Token {
        if c.options.count == 1 { return Token(tok(c.options[0].reading), space: space) }
        return Token(
            .choice(
                c.options.map { Alt(toks: [Token(tok($0.reading), space: space)], label: $0.label) },
                offer: c.offer
            ),
            space: space
        )
    }

    func tok(_ r: Reading) -> Tok {
        switch r {
        case .unit(let u): return .unit(u)
        case .scale(let n, let s): return .scale(n, s)
        }
    }

    // MARK: Run

    mutating func run() throws -> [Token] {
        let hasEach = raws.contains {
            if case .word(let w) = $0.raw { return w.lowercased() == "each" || w == "stk" }
            return false
        }
        while i < raws.count {
            let r = raws[i]
            switch r.raw {
            case .date(let d):
                push(.date(d), space: r.space)
                i += 1
            case .slashDate(let a, let b, let y):
                let dm = Alt(
                    toks: [Token(.date(DateLit(year: y, month: b, day: a)), space: r.space)],
                    label: "\(Resolver.monthLabel(b, locale)) \(a)"
                )
                let md = Alt(
                    toks: [Token(.date(DateLit(year: y, month: a, day: b)), space: r.space)],
                    label: "\(Resolver.monthLabel(a, locale)) \(b)"
                )
                push(.choice(locale.dayFirst ? [dm, md] : [md, dm], offer: true), space: r.space)
                i += 1
            case .clock(let c):
                var c = c
                i += 1
                if let w = word(i)?.lowercased(), w == "am" || w == "pm" {
                    c.h = Resolver.meridiem(c.h, w)
                    i += 1
                }
                push(.clock(c), space: r.space)
            case .number(let text, let radix, let options, let offer, _):
                try number(text, radix: radix, options: options, offer: offer, space: r.space)
            case .sym(let s):
                try symbol(s, space: r.space)
            case .word(let w):
                try wordTok(w, space: r.space, hasEach: hasEach)
            }
        }
        return out
    }

    static func monthLabel(_ m: Int, _ locale: CalcLocale) -> String {
        let en = [
            "January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
            "November", "December",
        ]
        let nb = [
            "januar", "februar", "mars", "april", "mai", "juni", "juli", "august", "september", "oktober", "november",
            "desember",
        ]
        guard (1...12).contains(m) else { return "\(m)" }
        return locale.nb ? nb[m - 1] : en[m - 1]
    }

    static func meridiem(_ h: Int, _ w: String) -> Int {
        if w == "am" { return h == 12 ? 0 : h }
        return h == 12 ? 12 : h + 12
    }

    mutating func number(_ text: String, radix: Int, options: [(String, String?)], offer: Bool, space: Bool) throws {
        i += 1
        if radix != 10 {
            guard let b = BigInt(digits: Substring(text), radix: radix) else { throw LexFailure() }
            push(.num(.exact(Rational(b)), radix: radix), space: space)
            return
        }
        // Fraction bound to a unit: "1/4 inch", "3/4 cup".
        if options.count == 1, !text.contains("."), !text.contains(","), sym(i) == "/", !(raw(i)?.space ?? true),
            let r2 = raw(i + 1), case .number(let t2, 10, let o2, _, _) = r2.raw, !r2.space, o2.count == 1,
            !t2.contains("."), let next = word(i + 2), Units.lookup(next, norwegian: locale.acceptsNorwegian) != nil,
            let n = BigInt(text), let d = BigInt(o2[0].0), !d.isZero
        {
            i += 2
            push(.num(.exact(Rational(n, d)), radix: 10), space: space)
            try afterNumber(space: space)
            return
        }
        var alts: [Alt] = []
        for (s, label) in options {
            if s.hasPrefix("SPLIT:") {
                let p = s.split(separator: ":")
                alts.append(
                    Alt(
                        toks: [
                            Token(.num(Num(decimal: String(p[1]))!, radix: 10), space: space),
                            Token(.op(","), space: false),
                            Token(.num(Num(decimal: String(p[2]))!, radix: 10), space: false),
                        ],
                        label: label
                    )
                )
            } else {
                guard let n = Num(decimal: s) else { throw LexFailure() }
                alts.append(Alt(toks: [Token(.num(n, radix: text.contains("e") ? 1 : 10), space: space)], label: label))
            }
        }
        if alts.count == 1 && alts[0].toks.count == 1 {
            out.append(alts[0].toks[0])
        } else {
            push(.choice(alts, offer: offer), space: space)
        }
        try afterNumber(space: space)
    }

    /// Words glued to a number: dates ("1 jan", "17. mai"), meridiem, ordinals.
    mutating func afterNumber(space: Bool) throws {
        guard case .num(let n, _)? = out.last.map({ $0.tok }), let day = n.int else { return }
        // "17. mai"
        var k = i
        if sym(k) == ".", raw(k + 1)?.space == true { k += 1 }
        if let w = word(k)?.lowercased(), let m = Resolver.monthNames[w], (1...99).contains(day) {
            out.removeLast()
            var lit = DateLit(year: nil, month: m, day: day)
            k += 1
            if let r = raw(k), case .number(let t, 10, _, _, _) = r.raw, t.count == 4, let y = Int(t) {
                lit.year = y
                k += 1
            }
            i = k
            push(.date(lit), space: space)
            return
        }
        if let w = word(i)?.lowercased(), w == "am" || w == "pm", (1...12).contains(day) {
            out.removeLast()
            let clock = Token(.clock(ClockLit(h: Resolver.meridiem(day, w), m: 0, s: nil, parts: 1)), space: space)
            i += 1
            if w == "pm" {
                // "10 pm in nm": picometre when the clock reading fails.
                let pico = Units.lookup("pm", norwegian: false).map { unitChoice($0, space: true) }
                if let pico {
                    push(
                        .choice(
                            [
                                Alt(toks: [clock], label: nil),
                                Alt(toks: [Token(.num(n, radix: 10), space: space), pico], label: nil),
                            ],
                            offer: false
                        ),
                        space: space
                    )
                    return
                }
            }
            out.append(clock)
        }
    }

    mutating func symbol(_ s: String, space: Bool) throws {
        i += 1
        switch s {
        case "(", ")", "+", "*", "/", "^", ",", ";", "=", "!", "&", "|", "~", "//", "<<", ">>", "==", "!=", "<", ">",
            "<=", ">=":
            // "x" between numbers was a word; "-" handled below.
            push(.op(s), space: space)
        case "-":
            // Hyphenated number words: "fifty-five".
            push(.op("-"), space: space)
        case ".":
            throw LexFailure()
        case ":":
            throw LexFailure()
        default:
            throw LexFailure()
        }
    }

    mutating func wordTok(_ w: String, space: Bool, hasEach: Bool) throws {
        let lw = w.lowercased()
        // Multi-word phrases first (longest match): units, zones.
        for n in stride(from: 4, through: 2, by: -1) {
            guard let p = phrase(i, n) else { continue }
            let lp = p.lowercased()
            if lp == "speed of light" {
                i += n
                push(.ident("speedoflight"), space: space)
                return
            }
            if let z = Zones.lookup(p) {
                i += n
                push(zoneTok(z), space: space)
                skipTimeWord()
                return
            }
            if let c = Units.lookup(p, norwegian: locale.acceptsNorwegian), p.contains(" ") {
                i += n
                out.append(unitChoice(c, space: space))
                return
            }
        }
        i += 1

        // "5 % 3": modulo, or 5 % of 3.
        if w == "%", lastIsNumberish, let r = raw(i), case .number = r.raw {
            let mod = Alt(toks: [Token(.op("mod"), space: space)], label: nb("modulo", "modulo"))
            let pct = Alt(
                toks: [Token(.unit(Units.percent), space: space), Token(.kw("of"), space: true)],
                label: nb("% av", "% of")
            )
            push(.choice([mod, pct], offer: true), space: space)
            return
        }

        // Number words: "fifty-five", "one hundred and twenty", "to" (nb).
        if let v = numberWord(lw) {
            var total = 0
            var current = v
            func next() -> Int? {
                var k = i
                if sym(k) == "-", !(raw(k)?.space ?? true) { k += 1 }
                if let w2 = word(k)?.lowercased(), let v2 = numberWord(w2, after: true) {
                    i = k + 1
                    return v2
                }
                return nil
            }
            while true {
                if let w2 = word(i)?.lowercased(), w2 == "hundred" || w2 == "hundre" {
                    current *= 100
                    i += 1
                    continue
                }
                if let w2 = word(i)?.lowercased(), w2 == "thousand" || w2 == "tusen" {
                    total += current * 1000
                    current = 0
                    i += 1
                    if let v2 = next() { current = v2 }
                    continue
                }
                if let w2 = word(i)?.lowercased(), w2 == "and" || w2 == "og", let w3 = word(i + 1)?.lowercased(),
                    let v3 = numberWord(w3, after: true), v3 < 100
                {
                    i += 2
                    current += v3
                    continue
                }
                if let v2 = next() {
                    current += v2
                    continue
                }
                break
            }
            total += current
            // "two thirds", "one quarter"
            if let w2 = word(i)?.lowercased(), let d = Resolver.fractionWords[w2] {
                i += 1
                push(.num(Num(total, d), radix: 10), space: space)
                return
            }
            push(.num(Num(total), radix: 10), space: space)
            try afterNumber(space: space)
            return
        }

        // Identifiers with digits: unit powers (m2), log2/log10, otherwise unknown.
        if w.contains(where: { $0.isNumber }) {
            if Resolver.functions.contains(lw) {
                push(.ident(lw), space: space)
                return
            }
            if let last = w.last, last == "2" || last == "3", w.dropLast().allSatisfy({ !$0.isNumber }),
                let c = Units.lookup(String(w.dropLast()), norwegian: locale.acceptsNorwegian)
            {
                out.append(unitChoice(c, space: space))
                push(.op("^"), space: false)
                push(.num(Num(Int(String(last))!), radix: 10), space: false)
                return
            }
            push(.ident(w), space: space)
            return
        }

        // Dates and clocks.
        if let m = Resolver.monthNames[lw],
            !(lastTok?.kwText.map { ["in", "to", "as"].contains($0) } ?? false) || lw.count > 3
        {
            if let r = raw(i), case .number(let t, 10, _, _, _) = r.raw, let d = Int(t), (1...31).contains(d),
                t.count <= 2
            {
                var lit = DateLit(year: nil, month: m, day: d)
                i += 1
                if sym(i) == "," { i += 1 }
                if let r2 = raw(i), case .number(let t2, 10, _, _, _) = r2.raw, t2.count == 4, let y = Int(t2) {
                    lit.year = y
                    i += 1
                }
                push(.date(lit), space: space)
                return
            }
            if let r = raw(i), case .number(let t, 10, _, _, _) = r.raw, t.count == 4, let y = Int(t) {
                i += 1
                push(.dateWord("month:\(m):\(y)"), space: space)
                return
            }
        }
        switch lw {
        case "today", "tomorrow", "yesterday", "now", "idag", "imorgen", "igår", "nå":
            push(.dateWord(lw), space: space)
            return
        case "noon", "midday":
            push(.clock(ClockLit(h: 12, m: 0, s: nil, parts: 1)), space: space)
            return
        case "midnight", "midnatt":
            push(.clock(ClockLit(h: 0, m: 0, s: nil, parts: 1)), space: space)
            return
        case "kl", "klokka", "klokken":
            if let r = raw(i), case .number(let t, 10, _, _, _) = r.raw, let h = Int(t), (0...24).contains(h) {
                i += 1
                push(.clock(ClockLit(h: h, m: 0, s: nil, parts: 1)), space: space)
                return
            }
            if let r = raw(i), case .clock = r.raw { return }
        default:
            break
        }
        if let z = Zones.lookup(w), !(Units.lookup(w, norwegian: locale.acceptsNorwegian) != nil && lastIsNumberish) {
            push(zoneTok(z), space: space)
            skipTimeWord()
            return
        }

        // Keywords and operators.
        switch lw {
        case "plus", "pluss":
            push(.op("+"), space: space)
            return
        case "minus":
            push(.op("-"), space: space)
            return
        case "times", "ganger":
            push(.op("*"), space: space)
            return
        case "mod", "modulo":
            push(.op("mod"), space: space)
            return
        case "xor":
            push(.op("xor"), space: space)
            return
        case "choose":
            push(.op("choose"), space: space)
            return
        case "x":
            if lastIsNumberish || lastTok?.opText == ")" {
                push(.op("*"), space: space)
                return
            }
        case "hex", "hexadecimal", "binary", "bin", "octal", "oct", "decimal", "dec", "heksadesimal", "binær",
            "desimal":
            if let k = lastTok?.kwText, ["in", "to", "as", "into"].contains(k) {
                let radix =
                    ["hex", "hexadecimal", "heksadesimal"].contains(lw)
                    ? 16 : (["binary", "bin", "binær"].contains(lw) ? 2 : (["octal", "oct"].contains(lw) ? 8 : 10))
                push(.radixTarget(radix), space: space)
                return
            }
        case "base":
            if let r = raw(i), case .number(let t, 10, _, _, _) = r.raw, let b = Int(t), (2...36).contains(b) {
                i += 1
                push(.radixTarget(100 + b), space: space)
                return
            }
        case "unix", "epoch":
            push(.dateWord("unix"), space: space)
            return
        case "each", "stk":
            return
        default:
            break
        }
        if lw == "in" {
            // Inch after a bare number ("10 in cm", "6 ft 2 in"), keyword otherwise.
            let inch = Token(.unit(Units.inch), space: space)
            let kw = Token(.kw("in"), space: space)
            // Right after a conversion keyword it is the unit ("5 ft in in").
            if let k = lastTok?.kwText, ["in", "to", "as", "into"].contains(k) {
                out.append(inch)
                return
            }
            // Inches only after a bare number and before a unit, a number, "in" or the end.
            let nextIsUnitish: Bool = {
                guard let r = raw(i) else { return true }
                switch r.raw {
                case .number, .sym: return true
                case .word(let nw):
                    if nw.lowercased() == "in" { return true }
                    if scale(nw.lowercased()) != nil || Zones.lookup(nw) != nil { return false }
                    return Units.lookup(nw, norwegian: locale.acceptsNorwegian) != nil
                default: return false
                }
            }()
            guard lastIsNumberish && nextIsUnitish else {
                out.append(kw)
                return
            }
            push(.choice([Alt(toks: [inch], label: nil), Alt(toks: [kw], label: nil)], offer: false), space: space)
            return
        }
        if lw == "the" || lw == "det" { return }
        if w == "a" || w == "an" || (locale.acceptsNorwegian && ["en", "et", "ei", "ett"].contains(lw)) {
            let nextWord = word(i)
            let nextIsUnit = nextWord.map { Units.lookup($0, norwegian: locale.acceptsNorwegian) != nil } ?? false
            let nextIsCount =
                nextWord.map {
                    scale($0.lowercased()) != nil || numberWord($0.lowercased(), after: true) != nil
                        || Resolver.fractionWords[$0.lowercased()] != nil
                } ?? false
            let prefixedAmount: Bool = {
                guard out.count >= 2, out.last?.isNumber == true else { return false }
                return out[out.count - 2].unit?.dim == .money
            }()
            // "8 hours a day", "$24 a day": per. "a year", "a million": one.
            if nextIsUnit, lastEndsQuantity, !lastIsNumberish || prefixedAmount {
                push(.op("/"), space: space)
                return
            }
            if nextIsUnit || nextIsCount
                || (nextWord != nil && Zones.lookup(nextWord!) == nil && sym(i) == nil && false)
            {
                push(.num(.one, radix: 10), space: space)
                return
            }
        }
        if Resolver.keywords.contains(lw) {
            push(.kw(lw), space: space)
            return
        }
        let afterClock: Bool = {
            if case .clock? = lastTok?.tok { return true }
            return false
        }()
        if lastIsNumberish || afterClock, Units.lookup(w, norwegian: locale.acceptsNorwegian) != nil,
            Resolver.functions.contains(lw)
        {
            out.append(unitChoice(Units.lookup(w, norwegian: locale.acceptsNorwegian)!, space: space))
            return
        }
        if Resolver.functions.contains(lw) {
            push(.ident(lw), space: space)
            return
        }
        if Resolver.constants.contains(lw) {
            push(.ident(lw), space: space)
            return
        }
        // Scale words; "K"/"k"/"M" glued to a number.
        if let (n, name) = scale(lw), !(w == "K" || w == "M") || (lastIsNumberish && !(w == "K" && space)) {
            if w == "K" && !space && lastIsNumberish {
                push(
                    .choice(
                        [
                            Alt(toks: [Token(.scale(n, name), space: space)], label: nil),
                            Alt(toks: [Token(.unit(Units.kelvin), space: space)], label: nil),
                        ],
                        offer: false
                    ),
                    space: space
                )
                return
            }
            if name == "billion" && locale.nb {
                push(
                    .choice(
                        [
                            Alt(toks: [Token(.scale(n, name), space: space)], label: "norsk billion (10^12)"),
                            Alt(
                                toks: [Token(.scale(Num(1_000_000_000), name), space: space)],
                                label: "English billion (10^9)"
                            ),
                        ],
                        offer: true
                    ),
                    space: space
                )
                return
            }
            push(.scale(n, name), space: space)
            return
        }
        if w == "M" {
            push(.scale(Num(1_000_000), "million"), space: space)
            return
        }
        if let c = Units.lookup(w, norwegian: locale.acceptsNorwegian) {
            // "m": metre or minute.
            if w == "m" {
                push(
                    .choice(
                        [
                            Alt(toks: [Token(.unit(Units.metre), space: space)], label: nil),
                            Alt(toks: [Token(.unit(Units.minute), space: space)], label: nil),
                        ],
                        offer: false
                    ),
                    space: space
                )
                return
            }
            out.append(unitChoice(c, space: space))
            return
        }
        // Unknown noun after a number in "N things at P each": drop it.
        if hasEach && lastIsNumberish { return }
        // An ingredient or label between a quantity and a conversion: "1 cup flour in grams".
        let lastIsUnit: Bool = {
            if lastTok?.unit != nil { return true }
            if case .choice(let alts, _)? = lastTok?.tok { return alts.first?.toks.last?.unit != nil }
            return false
        }()
        if lastIsUnit, let nw = word(i)?.lowercased(), ["in", "to", "i", "into"].contains(nw) { return }
        push(.ident(w), space: space)
    }

    func nb(_ en: String, _ no: String) -> String { locale.nb ? no : en }

    func numberWord(_ w: String, after: Bool = false) -> Int? {
        if let v = Resolver.numberWordsEn[w] { return v }
        if locale.acceptsNorwegian, let v = Resolver.numberWordsNb[w] {
            // Articles "en/et/ei" count as one only before a unit or number word.
            if ["en", "et", "ei", "ett"].contains(w) && !after { return nil }
            if w == "to" && !after {
                // "to" is two at the start or after an operator; otherwise a keyword.
                if let last = lastTok, !(last.opText != nil || last.kwText != nil) { return nil }
            }
            return v
        }
        return nil
    }

    /// "texas time", "oslo time": the word adds nothing after a zone.
    mutating func skipTimeWord() {
        if let w = word(i)?.lowercased(), w == "time" || w == "tid" { i += 1 }
    }

    func zoneTok(_ z: Zones.Match) -> Tok {
        if z.zones.count == 1 { return .zone(z.zones[0]) }
        return .choice(z.zones.map { Alt(toks: [Token(.zone($0))], label: $0.label) }, offer: true)
    }
}
