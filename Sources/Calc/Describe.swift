import Foundation

/// Human text for parsed queries and for dates.
enum Describe {
    static func node(_ n: Node, nb: Bool) -> String { node(n, nb ? .nb : .en) }

    /// Binding strength of an operator, for brackets.
    private static func strength(_ n: Node) -> Int {
        switch n {
        case .binary(let op, _, _):
            switch op {
            case "+", "-", "and": return 70
            case "*", "/", "juxt", "for", "of", "mod", "//": return 80
            case "at": return 75
            case "^": return 100
            default: return 60
            }
        case .convert: return 10
        default: return 1000
        }
    }

    static func node(_ n: Node, _ loc: CalcLocale) -> String {
        let nb = loc.nb
        func num(_ x: Num) -> String { Format.display(x, locale: loc) }
        func child(_ x: Node, _ parent: Int, right: Bool, op: String) -> String {
            let s = strength(x)
            let text = node(x, loc)
            if s < parent || (right && s == parent && ["/", "-", "juxt"].contains(op) && s < 100) {
                if case .binary("juxt", _, _) = x, isQuantityChain(x) { return text }
                return "(" + text + ")"
            }
            return text
        }
        switch n {
        case .num(let x, let radix):
            if radix == 16, let b = x.bigInt { return "0x" + b.toString(radix: 16).uppercased() }
            if let r = x.rational, !r.isInteger, let d = r.den.int, Format.canonical(x).count > 6, d <= 100 {
                return "\(r.num)/\(r.den)"
            }
            return num(x)
        case .unit(let u): return u.words.map { (nb ? u.wordsNb ?? $0 : $0).0 } ?? u.symbol
        case .scale(let x, _): return num(x)
        case .ident(let s): return s == "pi" ? "π" : (s == "speedoflight" ? "c" : s)
        case .date(let d):
            return d.year.map { String(format: "%04d-%02d-%02d", $0, d.month, d.day) }
                ?? (nb
                    ? "\(d.day). \(Resolver.monthLabel(d.month, loc))"
                    : "\(d.day) \(Resolver.monthLabel(d.month, loc))")
        case .dateWord(let w):
            if w.hasPrefix("month:") {
                let p = w.split(separator: ":")
                return Resolver.monthLabel(Int(p[1])!, loc) + " " + p[2]
            }
            return w
        case .clock(let c): return String(format: "%02d:%02d", c.h, c.m)
        case .zoned(let x, let z): return node(x, loc) + " " + (z.short ?? z.label)
        case .binary(let op, let a, let b):
            let sym: String
            switch op {
            case "*", "juxt", "for": sym = " × "
            case "/": sym = " ÷ "
            case "-": sym = " − "
            case "of": sym = nb ? " av " : " of "
            case "at": sym = " @ "
            case "and": sym = " + "
            case "on": sym = " "
            default: sym = " \(op) "
            }
            if op == "/", case .num(let x, _) = a, case .num(let y, _) = b, let xi = x.int, let yi = y.int, xi < 100,
                yi < 100
            {
                return "\(xi)/\(yi)"
            }
            if op == "juxt", case .unit = b { return child(a, 10, right: false, op: op) + " → " + node(b, loc) }
            if op == "juxt" || op == "and", case .quantity = b, isQuantityChain(a) {
                return node(a, loc) + " " + node(b, loc)
            }
            let p = strength(n)
            return child(a, p, right: false, op: op) + sym + child(b, p, right: true, op: op)
        case .unary(let op, let a):
            return (op == "delta" ? "Δ" : (op == "-" ? "−" : op)) + child(a, 90, right: false, op: op)
        case .postfix(let op, let a):
            return child(a, 110, right: false, op: op) + (op == "ago" ? (nb ? " siden" : " ago") : op)
        case .call("id", let args): return args.first.map { node($0, loc) } ?? ""
        case .call(let f, let args):
            if f == "sqrt" || f == "cbrt", args.count == 1 {
                let inner = node(args[0], loc)
                return (f == "sqrt" ? "√" : "∛") + (inner.contains(" ") ? "(" + inner + ")" : inner)
            }
            return f + "(" + args.map { node($0, loc) }.joined(separator: loc.decimalMark == "," ? "; " : ", ") + ")"
        case .convert(let a, let t, let rate):
            if case .expr(let x) = t { return node(a, loc) + (nb ? " i " : " in ") + node(x, loc) }
            return node(a, loc) + (rate.map { " @ " + node($0, loc) } ?? "") + " → " + target(t, nb: nb)
        case .quantity(let x, let ups):
            return node(x, loc) + " " + UnitText.text(ups, nb: nb)
        case .assign(let name, let e): return name + " = " + node(e, loc)
        case .seq(let ns): return ns.map { node($0, loc) }.joined(separator: "; ")
        }
    }

    static func isQuantityChain(_ n: Node) -> Bool {
        switch n {
        case .quantity: return true
        case .binary("juxt", let a, let b), .binary("and", let a, let b):
            return isQuantityChain(a) && isQuantityChain(b)
        default: return false
        }
    }

    static func target(_ t: Target, nb: Bool) -> String {
        switch t {
        case .units(let ups, let f):
            if ups.count == 1, ups[0].power == 1,
                let w = nb ? ups[0].unit.wordsNb ?? ups[0].unit.words : ups[0].unit.words
            {
                return w.1
            }
            return f.equals(.one) ? UnitText.text(ups, nb: nb) : UnitText.scaled(ups, factor: f, nb: nb)
        case .multi(let us): return us.map(\.symbol).joined(separator: " ")
        case .radix(let r):
            return r == 16 ? "hex" : (r == 2 ? "bin" : (r == 8 ? "oct" : (r == 10 ? "dec" : "base \(r - 100)")))
        case .percent: return "%"
        case .zone(let z): return z.short ?? z.label
        case .unix: return "unix"
        case .expr(let n): return node(n, nb: nb)
        case .list(let ts): return ts.map { target($0, nb: nb) }.joined(separator: ", ")
        case .scale(_, let name): return name
        case .unknown(let w): return w
        }
    }

    static func date(_ y: Int, _ m: Int, _ d: Int, nb: Bool) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = cal.date(from: DateComponents(year: y, month: m, day: d)) else { return "\(y)-\(m)-\(d)" }
        let f = DateFormatter()
        f.locale = Locale(identifier: nb ? "nb_NO" : "en_GB")
        f.timeZone = cal.timeZone
        f.dateFormat = nb ? "EEEE d. MMMM yyyy" : "EEEE d MMMM yyyy"
        return f.string(from: date)
    }

    /// "02:00", and "Tuesday 24 November · Oslo" (the date only when it isn't today there).
    static func instantParts(_ date: Date, _ tz: TimeZone, nb: Bool, now: Date) -> (String, String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: nb ? "nb_NO" : "en_GB")
        f.timeZone = tz
        f.dateFormat = "HH:mm"
        let time = f.string(from: date)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var parts: [String] = []
        if !cal.isDate(date, inSameDayAs: now) {
            f.dateFormat = nb ? "EEEE d. MMMM" : "EEEE d MMMM"
            if !cal.isDate(date, equalTo: now, toGranularity: .year) { f.dateFormat += " yyyy" }
            parts.append(f.string(from: date))
        }
        parts.append(place(tz, at: date))
        return (time, parts.joined(separator: " · "))
    }

    /// "Oslo", "New York", or "UTC−5" for a fixed offset.
    static func place(_ tz: TimeZone, at date: Date) -> String {
        if tz.identifier.contains("/") {
            return String(tz.identifier.split(separator: "/").last!).replacingOccurrences(of: "_", with: " ")
        }
        let s = tz.secondsFromGMT(for: date)
        if s == 0 { return "UTC" }
        let h = abs(s) / 3600
        let m = (abs(s) % 3600) / 60
        return "UTC" + (s < 0 ? "−" : "+") + "\(h)" + (m > 0 ? String(format: ":%02d", m) : "")
    }

    /// "02:00 Tuesday 24 November" in the zone, the date only when it isn't today.
    static func instant(_ date: Date, _ tz: TimeZone, nb: Bool, now: Date, local: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: nb ? "nb_NO" : "en_GB")
        f.timeZone = tz
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let sameDay = cal.isDate(date, inSameDayAs: now)
        f.dateFormat = sameDay ? "HH:mm" : (nb ? "HH:mm EEEE d. MMMM" : "HH:mm EEEE d MMMM")
        if !cal.isDate(date, equalTo: now, toGranularity: .year) { f.dateFormat += " yyyy" }
        return f.string(from: date)
    }
}
