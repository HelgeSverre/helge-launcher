import Foundation

struct UnitPow {
    var unit: UnitDef
    var power: Int
}

indirect enum Node {
    case num(Num, radix: Int)
    case unit(UnitDef)
    case scale(Num, String)
    case ident(String)
    case date(DateLit)
    case dateWord(String)
    case clock(ClockLit)
    case zoned(Node, ZoneLit)
    case binary(String, Node, Node)
    case unary(String, Node)
    case postfix(String, Node)
    case call(String, [Node])
    case convert(Node, Target, rate: Node?)
    /// A number with units written after it.
    case quantity(Node, [UnitPow])
    case assign(String, Node)
    case seq([Node])

    /// A bare literal: nothing to calculate.
    var isTrivial: Bool {
        switch self {
        case .num(_, let radix): return radix == 10
        case .unit, .scale, .clock, .date: return true
        case .ident(let s): return Resolver.constantNames.contains(s)
        case .quantity(let n, _): return n.isTrivial
        case .unary("-", let n), .unary("+", let n): return n.isTrivial
        case .postfix("%", let n), .postfix("‰", let n): return n.isTrivial
        case .zoned(let n, _): return n.isTrivial
        default: return false
        }
    }
}

indirect enum Target {
    case units([UnitPow], factor: Num)
    case multi([UnitDef])
    case radix(Int)
    case percent
    case zone(ZoneLit)
    case unix
    case expr(Node)
    case list([Target])
    case scale(Num, String)
    case unknown(String)
}

struct ParseError: Error {}

extension Resolver {
    static let constantNames: Set<String> = ["pi", "e", "tau", "phi", "speedoflight"]
}

struct Parser {
    var toks: [Token]
    var i = 0
    /// Implicit multiplication binds tighter than `*` and `/` ("8/2(2+2)" = 1).
    var tightJuxtaposition = false
    var depth = 0
    /// The next number is an exponent: units after it belong to the whole expression ("2^32 bytes").
    var noUnits = false

    init(_ toks: [Token], tight: Bool = false) {
        self.toks = toks
        tightJuxtaposition = tight
    }

    var peek: Tok? { i < toks.count ? toks[i].tok : nil }
    var peekToken: Token? { i < toks.count ? toks[i] : nil }

    mutating func next() -> Tok? {
        defer { i += 1 }
        return peek
    }

    mutating func parseProgram() throws -> Node {
        var stmts: [Node] = []
        while true {
            if case .ident(let name)? = peek, i + 1 < toks.count, toks[i + 1].opText == "=" {
                i += 2
                stmts.append(.assign(name, try parseExpr(0)))
            } else {
                stmts.append(try parseExpr(0))
            }
            if peek.map({
                if case .op(";") = $0 { return true }
                return false
            }) == true {
                i += 1
                continue
            }
            break
        }
        guard i == toks.count else { throw ParseError() }
        return stmts.count == 1 ? stmts[0] : .seq(stmts)
    }

    // MARK: Pratt

    /// Left binding power of the next token, and its operator name.
    func infix() -> (Int, String)? {
        guard let t = peek else { return nil }
        switch t {
        case .op(let s):
            switch s {
            case "(": return (tightJuxtaposition ? 85 : 80, "juxt")
            case "==", "!=", "<", ">", "<=", ">=": return (20, s)
            case "|": return (30, s)
            case "xor": return (40, s)
            case "&": return (50, s)
            case "<<", ">>": return (60, s)
            case "+", "-": return (70, s)
            case "*", "/", "mod", "//", "choose": return (80, s)
            case "^": return (100, s)
            case "!": return (110, "!")
            case ",":
                // ", in usd": a separator before a conversion.
                if i + 1 < toks.count, let k = toks[i + 1].kwText, ["in", "to", "as", "into"].contains(k) {
                    return (10, ",")
                }
                return nil
            default: return nil
            }
        case .kw(let k):
            switch k {
            case "in", "to", "as", "into": return (10, "in")
            case "at", "for": return (75, k)
            case "per": return (80, "/")
            case "of": return (80, "of")
            case "on": return (95, "on")
            case "ago": return (110, "ago")
            case "and":
                return (85, "and")
            default: return nil
            }
        case .unit(let u) where u.id == "%" || u.id == "‰":
            return (110, u.id)
        case .zone:
            return (105, "zone")
        default:
            // Implicit multiplication / juxtaposition before anything that starts an operand.
            if startsOperand(t) { return (tightJuxtaposition ? 85 : 80, "juxt") }
            return nil
        }
    }

    func startsOperand(_ t: Tok) -> Bool {
        switch t {
        case .num, .unit, .scale, .ident, .date, .clock, .dateWord: return true
        case .op("("): return true
        default: return false
        }
    }

    mutating func parseExpr(_ minBP: Int) throws -> Node {
        depth += 1
        defer { depth -= 1 }
        if depth > 200 { throw ParseError() }
        var left = try parsePrefix()
        while let (bp, op) = infix(), bp >= minBP {
            switch op {
            case ",":
                i += 1
            case "in":
                i += 1
                let target = try parseTarget()
                var rate: Node?
                if case .kw("at")? = peek {
                    i += 1
                    rate = try parseExpr(76)
                }
                left = .convert(left, target, rate: rate)
            case "!", "%", "‰", "ago":
                i += 1
                left = .postfix(op, left)
            case "zone":
                guard case .zone(let z)? = next() else { throw ParseError() }
                left = .zoned(left, z)
            case "^":
                i += 1
                noUnits = true
                let rhs = try parseExpr(bp)  // right-associative
                noUnits = false
                left = .binary("^", left, rhs)
            case "juxt":
                left = .binary("juxt", left, try parseExpr(bp + 1))
            default:
                i += 1
                left = .binary(op, left, try parseExpr(bp + 1))
            }
        }
        return left
    }

    mutating func parsePrefix() throws -> Node {
        guard let t = next() else { throw ParseError() }
        switch t {
        case .op("-"):
            return .unary("-", try parseExpr(90))
        case .op("+"):
            return try parseExpr(90)
        case .op("~"):
            return .unary("~", try parseExpr(90))
        case .op("("):
            let e = try parseExpr(0)
            if case .op(")")? = peek {
                i += 1
            }  // unclosed parens close at the end
            else if peek != nil {
                throw ParseError()
            }
            return e.isTrivial ? .call("id", [e]) : e
        case .num(let n, let radix):
            return try numberTail(.num(n, radix: radix))
        case .scale(let n, let name):
            return .scale(n, name)
        case .unit(let u):
            // Prefix currency: "$100", "kr 99,90".
            if u.dim == .money, case .num(let n, let r)? = peek {
                i += 1
                var node: Node = .num(n, radix: r)
                while case .scale(let k, _)? = peek {
                    i += 1
                    node = .binary("*", node, .num(k, radix: 10))
                }
                var ups = [UnitPow(unit: u, power: 1)]
                try absorbPer(&ups)
                return .quantity(node, ups)
            }
            if u.id == "%" { throw ParseError() }
            var ups = [UnitPow(unit: u, power: 1)]
            try unitPower(&ups)
            try absorbPer(&ups)
            return ups.count == 1 && ups[0].power == 1 ? .unit(u) : .quantity(.num(.one, radix: 10), ups)
        case .ident(let name):
            if name == "delta" { return .unary("delta", try parseExpr(90)) }
            if name == "sq" || name == "square" || name == "cubic" {
                guard case .unit(let u)? = next() else { throw ParseError() }
                return .quantity(.num(.one, radix: 10), [UnitPow(unit: u, power: name == "cubic" ? 3 : 2)])
            }
            if Resolver.functions.contains(name) {
                if case .op("(")? = peek {
                    i += 1
                    var args: [Node] = []
                    if case .op(")")? = peek {
                        i += 1
                        return .call(name, args)
                    }
                    while true {
                        args.append(try parseExpr(0))
                        if let o = peekToken?.opText, o == "," || o == ";" {
                            i += 1
                            continue
                        }
                        break
                    }
                    if case .op(")")? = peek { i += 1 } else if peek != nil { throw ParseError() }
                    return .call(name, args)
                }
                // "sqrt 2": applies to the next operand, above multiplication.
                return .call(name, [try parseExpr(90)])
            }
            return .ident(name)
        case .date(let d):
            return .date(d)
        case .dateWord(let w):
            return .dateWord(w)
        case .clock(let c):
            if case .unit(let u)? = peek, u.dim == .time {
                // "5:00 min/km": minutes and seconds of a pace.
                return try numberTail(.num(.zero, radix: 10), clock: c)
            }
            return .clock(c)
        case .zone(let z):
            return .zoned(.dateWord("now"), z)
        default:
            throw ParseError()
        }
    }

    /// Scales and units after a number: "2 million", "10 km", "5 m^2", "1 sq ft".
    mutating func numberTail(_ base: Node, clock: ClockLit? = nil) throws -> Node {
        var node = base
        if noUnits {
            noUnits = false
            return node
        }
        if let c = clock {
            // Pace m:ss → minutes.
            node = .num(Num(c.h) + Num(c.m, 60) + Num(c.s ?? 0, 3600), radix: 10)
        }
        while case .scale(let n, _)? = peek {
            i += 1
            if case .num(let v, let r) = node {
                node = .num(v * n, radix: r == 1 ? 10 : r)
            } else {
                node = .binary("*", node, .num(n, radix: 10))
            }
        }
        var ups: [UnitPow] = []
        while let t = peek {
            if case .unit(let u) = t, u.id != "%" && u.id != "‰" {
                i += 1
                ups.append(UnitPow(unit: u, power: 1))
                try unitPower(&ups)
                try absorbPer(&ups)
                // Only one unit binds to the number; "6 ft 2 in" juxtaposes.
                break
            }
            if case .ident(let w) = t, w == "sq" || w == "square" || w == "cubic",
                i + 1 < toks.count, case .unit(let u) = toks[i + 1].tok
            {
                i += 2
                ups.append(UnitPow(unit: u, power: w == "cubic" ? 3 : 2))
                break
            }
            break
        }
        return ups.isEmpty ? node : .quantity(node, ups)
    }

    /// "km/h", "kJ/kg/K", "kr per ml": a slash and a bare unit stay part of the quantity's unit.
    mutating func absorbPer(_ ups: inout [UnitPow]) throws {
        while i + 1 < toks.count {
            let isSlash = toks[i].opText == "/" || toks[i].kwText == "per"
            guard isSlash, case .unit(let u) = toks[i + 1].tok, u.id != "%" else { return }
            // Not when a number follows the unit ("/ h 2").
            i += 2
            var up = [UnitPow(unit: u, power: 1)]
            try unitPower(&up)
            ups.append(UnitPow(unit: u, power: -up[0].power))
        }
    }

    /// "^2" directly after a unit raises the unit, not the quantity.
    mutating func unitPower(_ ups: inout [UnitPow]) throws {
        if case .op("^")? = peek, i + 1 < toks.count {
            var k = i + 1
            var sign = 1
            if toks[k].opText == "-" {
                sign = -1
                k += 1
            }
            if k < toks.count, case .num(let n, _) = toks[k].tok, let p = n.int, (1...9).contains(p) {
                ups[ups.count - 1].power *= sign * p
                i = k + 1
            }
        }
    }

    // MARK: Targets

    mutating func parseTarget() throws -> Target {
        var targets: [Target] = [try parseOneTarget()]
        while let o = peekToken?.opText, o == ",", i + 1 < toks.count, case .unit = toks[i + 1].tok {
            i += 1
            targets.append(try parseOneTarget())
        }
        return targets.count == 1 ? targets[0] : .list(targets)
    }

    mutating func parseOneTarget() throws -> Target {
        guard let t = peek else { throw ParseError() }
        switch t {
        case .zone(let z):
            i += 1
            return .zone(z)
        case .radixTarget(let r):
            i += 1
            return .radix(r)
        case .dateWord("unix"):
            i += 1
            if case .ident(let w)? = peek, ["time", "timestamp", "seconds"].contains(w.lowercased()) { i += 1 }
            return .unix
        case .unit(let u) where u.id == "%" || u.id == "‰":
            i += 1
            return .percent
        case .scale(let n, let name):
            i += 1
            return .scale(n, name)
        case .num, .clock, .date, .dateWord, .op("("):
            return .expr(try parseExpr(11))
        case .ident(let w):
            if w == "sq" || w == "square" || w == "cubic" { return try parseUnitTarget() }
            if w == "fraction" || w == "a" { throw ParseError() }
            i += 1
            return .unknown(w)
        case .unit, .op("/"), .kw("per"):
            return try parseUnitTarget()
        default:
            throw ParseError()
        }
    }

    /// A unit at `k`, or a number then a unit ("100 km").
    func unitFollows(_ k: Int) -> Bool {
        guard k < toks.count else { return false }
        if case .unit(let u) = toks[k].tok { return u.id != "%" }
        if case .ident(let w) = toks[k].tok, ["sq", "square", "cubic"].contains(w) { return true }
        if case .num = toks[k].tok, k + 1 < toks.count, case .unit = toks[k + 1].tok { return true }
        return false
    }

    /// "km/h", "kg m^2 / s^3", "L/100 km", "feet and inches", "days hours minutes seconds".
    mutating func parseUnitTarget() throws -> Target {
        var ups: [UnitPow] = []
        var factor = Num.one
        var denominator = false
        var sawSlash = false
        var multi: [UnitDef] = []
        var multiOK = true
        while let t = peek {
            switch t {
            case .op("/") where !ups.isEmpty && !unitFollows(i + 1):
                break  // "in nok / 10": arithmetic on the result
            case .op("*") where !unitFollows(i + 1):
                break
            case .op("/"):
                i += 1
                denominator = true
                sawSlash = true
                multiOK = false
                continue
            case .op("*"):
                i += 1
                multiOK = false
                continue
            case .kw("and"):
                guard i + 1 < toks.count, case .unit = toks[i + 1].tok else { break }
                i += 1
                continue
            case .num(let n, _) where denominator:
                // "L/100 km"
                i += 1
                factor = factor / n
                continue
            case .ident(let w) where w == "sq" || w == "square" || w == "cubic":
                guard i + 1 < toks.count, case .unit(let u) = toks[i + 1].tok else { throw ParseError() }
                i += 2
                ups.append(UnitPow(unit: u, power: (w == "cubic" ? 3 : 2) * (denominator ? -1 : 1)))
                multiOK = false
                denominator = false
                continue
            case .unit(let u) where u.id != "%":
                i += 1
                var up = [UnitPow(unit: u, power: 1)]
                try unitPower(&up)
                if up[0].power != 1 { multiOK = false }
                if denominator { up[0].power = -up[0].power }
                ups.append(up[0])
                multi.append(u)
                denominator = false
                continue
            default:
                break
            }
            break
        }
        if ups.isEmpty && !sawSlash { throw ParseError() }
        if multiOK, multi.count > 1, Set(multi.map(\.dim)).count == 1 { return .multi(multi) }
        return .units(ups, factor: factor)
    }
}
