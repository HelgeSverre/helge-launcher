import Foundation

/// Evaluates one parsed reading. Holds per-query state: variables, extra alternatives, rate use.
final class Evaluator {
    let ctx: CalcContext
    var vars: [String: Value]
    /// Set when a currency conversion used exchange rates.
    var usedRates = false
    /// Alternatives the evaluation itself discovers (two's complement, delta vs reading, …).
    var extras: [(Value, String)] = []
    /// Gregorian, in the context's time zone, ISO weeks.
    var calendar: Calendar

    init(_ ctx: CalcContext) {
        self.ctx = ctx
        vars = ctx.variables
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ctx.timeZone
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
    }

    var nb: Bool { ctx.locale.nb }

    // MARK: Nodes

    func eval(_ n: Node) throws -> Value {
        switch n {
        case .num(let v, _):
            return .q(Quantity(v))
        case .unit(let u):
            var q = Quantity(.one, [UnitPow(unit: u, power: 1)])
            q.bare = true
            return .q(q)
        case .scale(let v, _):
            return .q(Quantity(v))
        case .ident(let name):
            return try ident(name)
        case .quantity(let inner, let ups):
            guard case .q(let q) = try eval(inner), q.isPlain else { throw EvalError.silent }
            var r = Quantity(q.value, ups)
            if ups.count == 1, ups[0].unit.dim == .temperature, ups[0].unit.offset != nil {
                try checkAbsolute(r)
            }
            r.hint = .none
            return .q(r)
        case .binary(let op, let a, let b):
            return try binary(op, a, b)
        case .unary(let op, let a):
            return try unary(op, try eval(a))
        case .postfix(let op, let a):
            return try postfix(op, try eval(a))
        case .call(let name, let args):
            return try call(name, args)
        case .convert(let a, let t, let rate):
            return try convert(a, t, rate: rate)
        case .date(let d):
            return try dateLiteral(d, zone: nil)
        case .dateWord(let w):
            return try dateWord(w)
        case .clock(let c):
            return .clock(c, zone: nil, dayOffset: 0)
        case .zoned(let inner, let z):
            switch inner {
            case .dateWord("now"): return .instant(ctx.now, z.zone)
            case .date(let d): return try dateLiteral(d, zone: z)
            default: break
            }
            guard case .clock(let c, nil, _) = try eval(inner) else { throw EvalError.silent }
            return .clock(c, zone: z, dayOffset: 0)
        case .assign(let name, let e):
            let v = try eval(e)
            vars[name] = v
            return v
        case .seq(let nodes):
            var last: Value = .bool(false)
            for x in nodes { last = try eval(x) }
            return last
        }
    }

    func ident(_ name: String) throws -> Value {
        if let v = vars[name] { return v }
        switch name {
        case "pi": return .q(Quantity(.approx(Double.pi)))
        case "e": return .q(Quantity(.approx(M_E)))
        case "tau": return .q(Quantity(.approx(2 * Double.pi)))
        case "phi": return .q(Quantity(.approx((1 + 5.0.squareRoot()) / 2)))
        case "speedoflight":
            return .q(
                Quantity(
                    Num(299_792_458),
                    [UnitPow(unit: Units.metre, power: 1), UnitPow(unit: Units.second, power: -1)]
                )
            )
        case "ans":
            if let a = ctx.previousAnswer { return a.value }
            throw EvalError.silent
        default:
            throw EvalError.silent
        }
    }

    // MARK: Units

    /// SI factor of a unit list; currencies use NOK per unit.
    func factor(_ ups: [UnitPow], rates: Bool) throws -> Num {
        var f = Num.one
        for up in ups {
            var uf = up.unit.factor
            if let code = up.unit.currency, rates {
                uf = uf * (try rate(code))
            }
            f = f * (try uf.power(Num(up.power)))
        }
        return f
    }

    func rate(_ code: String) throws -> Num {
        if code == "NOK" { return .one }
        guard let table = ctx.rates else {
            throw EvalError.show(
                nb
                    ? "Ingen valutakurser ennå. Koble til nettet én gang for å hente dem."
                    : "No exchange rates yet. Connect once to fetch them."
            )
        }
        guard let r = table.nokPer[code] else {
            throw EvalError.show(nb ? "Ingen kurs for \(code)" : "No rate for \(code)")
        }
        usedRates = true
        return r
    }

    /// Multiplier from `a` units to `b` units (same dimension). Currency rates cancel when both sides
    /// hold the same currencies.
    func ratio(_ a: [UnitPow], _ b: [UnitPow]) throws -> Num {
        var net: [String: Int] = [:]
        for up in a { if let c = up.unit.currency { net[c, default: 0] += up.power } }
        for up in b { if let c = up.unit.currency { net[c, default: 0] -= up.power } }
        let needRates = net.values.contains { $0 != 0 }
        let fa = try factor(a, rates: needRates)
        let fb = try factor(b, rates: needRates)
        return fa / fb
    }

    func describe(_ ups: [UnitPow]) -> String { UnitText.text(ups, nb: nb) }

    func dimMismatch(_ a: Quantity, _ b: Quantity, adding: Bool) -> EvalError {
        let an = unitName(a)
        let bn = unitName(b)
        if adding {
            return .show(
                nb
                    ? "Kan ikke legge sammen \(a.dim.name) (\(an)) og \(b.dim.name) (\(bn))"
                    : "Can't add \(a.dim.name) (\(an)) and \(b.dim.name) (\(bn))"
            )
        }
        return .show(
            nb ? "\(an) er \(a.dim.name), \(bn) er \(b.dim.name)" : "\(an) is \(a.dim.name), \(bn) is \(b.dim.name)"
        )
    }

    func unitName(_ q: Quantity) -> String { q.units.isEmpty ? (nb ? "tall" : "number") : describe(q.units) }

    func checkAbsolute(_ q: Quantity) throws {
        guard let u = q.absoluteTemperature else { return }
        let k = q.value * u.factor + (u.offset ?? .zero)
        if k.isNegative && !k.equals(.zero) {
            throw EvalError.show(nb ? "Under det absolutte nullpunkt (−273,15 °C)" : "Below absolute zero (−273.15 °C)")
        }
    }

    /// Kelvin of an absolute reading.
    func kelvin(_ q: Quantity) -> Num {
        let u = q.absoluteTemperature!
        return q.value * u.factor + (u.offset ?? .zero)
    }

    /// Converts `q` to `target` units; offsets apply to single absolute temperatures.
    func convertQ(_ q: Quantity, to target: [UnitPow]) throws -> Quantity {
        let tdim = target.reduce(Dim.none) { $0 + $1.unit.dim * $1.power }
        if q.dim != tdim {
            if !q.dim.isNone && q.dim == -tdim {
                // Reciprocal: min/km ↔ km/h, L/100 km ↔ mpg.
                guard !q.value.isZero else { throw EvalError.show(nb ? "Divisjon med null" : "Division by zero") }
                let inv = Quantity(Num.one / q.value, q.units.map { UnitPow(unit: $0.unit, power: -$0.power) })
                return try convertQ(inv, to: target)
            }
            var t = Quantity(.one, target)
            t.bare = true
            throw dimMismatch(q, t, adding: false)
        }
        if target.count == 1, target[0].power == 1, let tu = target[0].unit.offset.map({ _ in target[0].unit }),
            let su = q.absoluteTemperature
        {
            let k = q.value * su.factor + (su.offset ?? .zero)
            try checkAbsolute(q)
            return Quantity((k - (tu.offset ?? .zero)) / tu.factor, target)
        }
        if let su = q.absoluteTemperature, su.offset != nil, target.count == 1, target[0].unit.id == "K" {
            try checkAbsolute(q)
            return Quantity(kelvin(q), target)
        }
        var r = Quantity(q.value * (try ratio(q.units, target)), target)
        r.delta = q.delta
        return r
    }

    // MARK: Arithmetic on quantities

    func add(_ a: Quantity, _ b: Quantity, sign: Int) throws -> Quantity {
        // Percent of the left operand: 200 + 10%.
        if (b.isPercent || b.scaledPercent) && !(a.isPercent || a.scaledPercent) {
            let f = b.value * b.units[0].unit.factor
            var r = a
            r.value = a.value * (sign > 0 ? Num.one + f : Num.one - f)
            return r
        }
        var a = a
        var b = b
        // Unit assimilation: 300 + 20 km, $20 + 30.
        if a.isPlain && !b.isPlain && !b.isPercent { a.units = b.units }
        if b.isPlain && !a.isPlain && !a.isPercent { b.units = a.units }
        // Temperatures: reading ± difference, reading − reading.
        if let ua = a.absoluteTemperature {
            if let ub = b.absoluteTemperature {
                if sign < 0 {
                    let d = kelvin(a) - kelvin(b)
                    var r = Quantity(d / ua.factor, [UnitPow(unit: ua, power: 1)])
                    r.delta = true
                    return r
                }
                let bk = b.value * ub.factor
                var r = a
                r.value = a.value + bk / ua.factor
                try checkAbsolute(r)
                return r
            }
            if b.delta || b.singleUnit?.id == "K" || (b.dim == .temperature) {
                let bk = b.value * (b.singleUnit?.factor ?? .one)
                var r = a
                r.value = sign > 0 ? a.value + bk / ua.factor : a.value - bk / ua.factor
                try checkAbsolute(r)
                return r
            }
        }
        guard a.dim == b.dim else { throw dimMismatch(a, b, adding: true) }
        // Which unit the result keeps: the left for simple units, the right for compound ones and money.
        let simple = a.units.count == 1 && b.units.count == 1 && a.units[0].power == 1 && b.units[0].power == 1
        // Times keep the smaller unit (5 min + 30 s = 330 s).
        let smallerRight = simple && a.dim == .time && (b.units[0].unit.factor < a.units[0].unit.factor)
        let keepRight = !simple || a.hasMoney || smallerRight
        let target = keepRight ? b : a
        let other = keepRight ? a : b
        let conv = try other.units.isEmpty && target.units.isEmpty ? other : convertQ(other, to: target.units)
        var r = target
        if keepRight {
            r.value = sign > 0 ? conv.value + target.value : conv.value - target.value
        } else {
            r.value = sign > 0 ? target.value + conv.value : target.value - conv.value
        }
        r.bare = false
        r.scaledPercent = a.scaledPercent && b.scaledPercent
        if case .mixed = a.hint { r.hint = a.hint } else if case .mixed = b.hint { r.hint = b.hint }
        if a.dim == .time, case .mixed(let ua) = r.hint, let ub = b.singleUnit ?? b.units.first?.unit {
            r.hint = .mixed(ua.contains(ub) ? ua : ua + [ub])
        }
        if case .colon(let s1) = a.hint, case .colon(let s2) = b.hint { r.hint = .colon(seconds: s1 || s2) }
        r.delta = a.delta && b.delta
        return r
    }

    /// Multiplies unit lists; units of one dimension that meet with opposite signs cancel across operands.
    func multiplyUnits(_ a: [UnitPow], _ b: [UnitPow], bare: Bool = false) throws -> (Num, [UnitPow], Bool) {
        var units = a.flatMap(expand)
        var f = Num.one
        var cancelled = false
        let rhs = b.flatMap(expand)
        let leftLen = units.count
        for up in rhs {
            if let i = units.firstIndex(where: { $0.unit == up.unit }) {
                units[i].power += up.power
                cancelled = true
                continue
            }
            if !bare,
                let i = units.prefix(leftLen).firstIndex(where: {
                    $0.unit.dim == up.unit.dim && ($0.power > 0) != (up.power > 0) && $0.unit.offset == nil
                        && up.unit.offset == nil
                })
            {
                let r = try ratio([UnitPow(unit: up.unit, power: 1)], [UnitPow(unit: units[i].unit, power: 1)])
                f = f * (try r.power(Num(up.power)))
                units[i].power += up.power
                cancelled = true
                continue
            }
            units.append(up)
        }
        units.removeAll { $0.power == 0 }
        if !cancelled && units.count == a.count + b.count {
            // Nothing cancelled: keep the named compound units as written.
            return (.one, a + b, false)
        }
        return (f, units, cancelled)
    }

    /// Named compound units split into parts for cancellation: mph → mi/h, kWh → kW·h.
    func expand(_ up: UnitPow) -> [UnitPow] {
        let u = up.unit
        let p = up.power
        func parts(_ list: [(UnitDef, Int)]) -> [UnitPow] { list.map { UnitPow(unit: $0.0, power: $0.1 * p) } }
        switch u.id {
        case "mph": return parts([(Units.mile, 1), (Units.hour, -1)])
        case "km/h":
            return parts([
                (Units.prefixed(Units.metre, Units.siPrefixes.first { $0.sym == "k" }!), 1), (Units.hour, -1),
            ])
        case "kn": return parts([(Units.nmi, 1), (Units.hour, -1)])
        case "ppi": return parts([(Units.pixel, 1), (Units.inch, -1)])
        default: break
        }
        if u.id.hasSuffix("bps") {
            let prefix = String(u.id.dropLast(3))
            let bit =
                prefix.isEmpty ? Units.bit : Units.prefixed(Units.bit, Units.siPrefixes.first { $0.sym == prefix }!)
            return parts([(bit, 1), (Units.second, -1)])
        }
        if u.id.hasSuffix("Wh") {
            let prefix = String(u.id.dropLast(2))
            let w =
                prefix.isEmpty ? Units.watt : Units.prefixed(Units.watt, Units.siPrefixes.first { $0.sym == prefix }!)
            return parts([(w, 1), (Units.hour, 1)])
        }
        return [up]
    }

    func multiply(_ a: Quantity, _ b: Quantity) throws -> Quantity {
        // Percent: 50% * 30 = 15, but 10% * 2 stays a percent for 100 + 10% * 2.
        if a.isPercent && b.isPlain {
            var r = a
            r.value = a.value * b.value
            r.scaledPercent = true
            return r
        }
        if b.isPercent && a.isPlain {
            var r = b
            r.value = a.value * b.value
            r.scaledPercent = true
            return r
        }
        if a.isPercent && b.isPercent {
            return Quantity(a.value * a.units[0].unit.factor * b.value * b.units[0].unit.factor)
        }
        if a.isPercent || b.isPercent {
            let (p, o) = a.isPercent ? (a, b) : (b, a)
            var r = o
            r.value = o.value * p.value * p.units[0].unit.factor
            return r
        }
        // A temperature reading times a number scales the reading.
        if let u = a.absoluteTemperature, b.isPlain {
            var r = a
            r.value = a.value * b.value
            let k = kelvin(a) * b.value
            var alt = Quantity((k - (u.offset ?? .zero)) / u.factor, a.units)
            alt.hint = .none
            extras.append((.q(alt), nb ? "skalert absolutt temperatur" : "scale the absolute temperature"))
            return r
        }
        let (f, units, cancelled) = try multiplyUnits(a.units, b.units, bare: a.bare || b.bare)
        var r = Quantity(a.value * b.value * f, units)
        r.derived = cancelled || a.derived || b.derived
        r.delta = a.delta || b.delta
        return r
    }

    func divide(_ a: Quantity, _ b: Quantity) throws -> Quantity {
        if b.value.isZero {
            if a.value.isZero { throw EvalError.show(nb ? "Udefinert (0 ÷ 0)" : "Undefined (0 ÷ 0)") }
            throw EvalError.show(nb ? "Divisjon med null" : "Division by zero")
        }
        if b.isPercent || b.scaledPercent {
            var r = a
            r.value = a.value / (b.value * b.units[0].unit.factor)
            return r
        }
        var inv = Quantity(Num.one / b.value, b.units.map { UnitPow(unit: $0.unit, power: -$0.power) })
        inv.derived = b.derived
        inv.bare = b.bare
        var r = try multiply(a, inv)
        r.scaledPercent = a.scaledPercent
        return r
    }

    func power(_ a: Quantity, _ b: Quantity) throws -> Quantity {
        guard b.isPlain else {
            throw EvalError.show(nb ? "Eksponenten må være et tall uten enhet" : "The exponent must be a plain number")
        }
        if a.isPlain {
            do {
                return Quantity(try a.value.power(b.value))
            } catch NumError.tooLarge {
                throw EvalError.show(nb ? "Resultatet er for stort" : "Result too large to compute")
            } catch NumError.undefined(let m) {
                throw EvalError.show(m)
            }
        }
        guard let p = b.value.int else {
            throw EvalError.show(
                nb ? "Enheter kan bare opphøyes i hele tall" : "Units can only be raised to whole powers"
            )
        }
        return Quantity(try a.value.power(b.value), a.units.map { UnitPow(unit: $0.unit, power: $0.power * p) })
    }

    // MARK: Operators

    func binary(_ op: String, _ an: Node, _ bn: Node) throws -> Value {
        let a = try eval(an)
        if op == "on" {
            return try onDate(a, try eval(bn))
        }
        let b = try eval(bn)
        switch (a, b) {
        case (.q(let x), .q(let y)):
            return try binaryQ(op, x, y, an, bn)
        default:
            return try binaryTime(op, a, b)
        }
    }

    func requireInt(_ q: Quantity) throws -> BigInt {
        guard q.isPlain, let i = q.value.bigInt else {
            throw EvalError.show(nb ? "Trenger hele tall" : "Needs whole numbers")
        }
        return i
    }

    func binaryQ(_ op: String, _ x: Quantity, _ y: Quantity, _ an: Node, _ bn: Node) throws -> Value {
        switch op {
        case "+": return .q(try add(x, y, sign: 1))
        case "-": return .q(try add(x, y, sign: -1))
        case "*", "for": return .q(try multiply(x, y))
        case "/": return .q(try divide(x, y))
        case "^": return .q(try power(x, y))
        case "of":
            if x.isPercent || x.scaledPercent {
                var r = y
                r.value = y.value * x.value * x.units[0].unit.factor
                r.bare = false
                return .q(r)
            }
            guard x.isPlain else { throw EvalError.silent }
            var r = y
            r.value = x.value * y.value
            r.bare = false
            return .q(r)
        case "mod", "//":
            guard x.dim == y.dim else { throw dimMismatch(x, y, adding: true) }
            let yv = try convertQ(y, to: x.units).value
            if yv.isZero { throw EvalError.show(nb ? "Divisjon med null" : "Division by zero") }
            let q = (x.value / yv).rounded(.down)
            var r = x
            r.value = op == "mod" ? x.value - q * yv : q
            if op == "//" { r.units = [] }
            return .q(r)
        case "choose":
            let n = try requireInt(x)
            let k = try requireInt(y)
            guard let ni = n.int, let ki = k.int, ki >= 0, ki <= ni, ni <= 100_000 else {
                throw EvalError.show(nb ? "Ugyldig" : "Invalid")
            }
            var r = BigInt(1)
            let kk = min(ki, ni - ki)
            for j in 0..<kk { r = r * BigInt(ni - j) / BigInt(j + 1) }
            return .q(Quantity(.exact(Rational(r))))
        case "<<", ">>":
            let a = try requireInt(x)
            guard let s = try requireInt(y).int, s >= 0, s <= 100_000 else {
                throw EvalError.show("Shift out of range")
            }
            let p = BigInt(2).power(s)
            return .q(Quantity(.exact(Rational(op == "<<" ? a * p : a / p))))
        case "&", "|", "xor":
            let a = try requireInt(x)
            let b = try requireInt(y)
            guard !a.negative, !b.negative else {
                throw EvalError.show(
                    nb ? "Bitoperasjoner trenger ikke-negative tall" : "Bitwise operations need non-negative numbers"
                )
            }
            let r = op == "&" ? BigInt.bitAnd(a, b) : (op == "|" ? BigInt.bitOr(a, b) : BigInt.bitXor(a, b))
            return .q(Quantity(.exact(Rational(r))))
        case "==", "!=", "<", ">", "<=", ">=":
            guard x.dim == y.dim else { throw dimMismatch(x, y, adding: true) }
            let yv = try convertQ(y, to: x.units).value
            let eq = x.value.equals(yv)
            let lt = x.value < yv && !eq
            let r: Bool
            switch op {
            case "==": r = eq
            case "!=": r = !eq
            case "<": r = lt
            case ">": r = !lt && !eq
            case "<=": r = lt || eq
            default: r = !lt
            }
            return .bool(r)
        case "at":
            return .q(try at(x, y))
        case "juxt", "and":
            return .q(try juxtapose(x, y, an, bn, and: op == "and"))
        default:
            throw EvalError.silent
        }
    }

    /// "30 hours at $30/hour" multiplies (hours meet the rate's per-unit); "$500 at $20/hour" divides
    /// (dollars meet the rate's amount).
    func at(_ x: Quantity, _ y: Quantity) throws -> Quantity {
        let parts = y.units.flatMap(expand)
        let numDim = parts.filter { $0.power > 0 }.reduce(Dim.none) { $0 + $1.unit.dim * $1.power }
        let denDim = parts.filter { $0.power < 0 }.reduce(Dim.none) { $0 - $1.unit.dim * $1.power }
        if !x.dim.isNone, x.dim == numDim, !denDim.isNone, x.dim != denDim, !y.value.isZero {
            var r = try divide(x, y)
            if r.dim == .time { r = toDuration(r) }
            return r
        }
        return try multiply(x, y)
    }

    func juxtapose(_ x: Quantity, _ y: Quantity, _ an: Node, _ bn: Node, and: Bool) throws -> Quantity {
        // A quantity then a bare unit converts: "km m", "10 in cm".
        if y.bare && !x.isPlain && !and {
            var r = try convertQ(Quantity(x.value, x.units), to: y.units)
            r.bare = false
            return r
        }
        if !x.isPlain && !y.isPlain && x.dim == y.dim {
            // "6 ft 2 in", "2h 30m", "3 weeks 2 days 5 hours"
            var r = try add(x, y, sign: 1)
            if x.dim == .time || x.dim == .length {
                var list: [UnitDef] = []
                if case .mixed(let l) = x.hint { list = l } else if let u = x.singleUnit { list = [u] }
                if let u = y.singleUnit, !list.contains(u) { list.append(u) }
                r.hint = .mixed(list)
            }
            return r
        }
        if and { throw EvalError.silent }
        // Different kinds side by side only multiply for power × time ("60 W 24 hours").
        if !x.isPlain && !y.isPlain
            && !(x.dim == Units.power && y.units.contains { $0.unit.dim == .time && $0.power > 0 })
        {
            throw EvalError.silent
        }
        if x.isPlain && y.isPlain {
            // Number next to number ("47 912 34") is not a calculation; "2(3+4)" and "2pi" are.
            if case .num = an, case .num = bn { throw EvalError.silent }
            if case .quantity = an, case .num = bn { throw EvalError.silent }
        }
        if !x.isPlain && y.isPlain, case .num = bn { throw EvalError.silent }
        return try multiply(x, y)
    }

    func unary(_ op: String, _ v: Value) throws -> Value {
        guard case .q(var q) = v else { throw EvalError.silent }
        switch op {
        case "-":
            q.value = -q.value
            if q.absoluteTemperature != nil { try checkAbsolute(q) }
            return .q(q)
        case "~":
            let i = try requireInt(q)
            let r = -(i + BigInt(1))
            if !i.negative {
                let m32 = BigInt(2).power(32) - BigInt(1)
                let m64 = BigInt(2).power(64) - BigInt(1)
                if i < BigInt(2).power(32) {
                    extras.append(
                        (.text("0x" + (m32 - i).toString(radix: 16)), nb ? "32-bit uten fortegn" : "32-bit unsigned")
                    )
                }
                if i < BigInt(2).power(64) {
                    extras.append(
                        (.text("0x" + (m64 - i).toString(radix: 16)), nb ? "64-bit uten fortegn" : "64-bit unsigned")
                    )
                }
            }
            return .q(Quantity(.exact(Rational(r))))
        case "delta":
            q.delta = true
            return .q(q)
        default:
            throw EvalError.silent
        }
    }

    func postfix(_ op: String, _ v: Value) throws -> Value {
        switch op {
        case "!":
            guard case .q(let q) = v, q.isPlain, let n = q.value.int, n >= 0 else {
                throw EvalError.show(nb ? "Fakultet trenger et helt tall" : "Factorial needs a whole number")
            }
            guard n <= 3000 else {
                throw EvalError.show(nb ? "Resultatet er for stort" : "Result too large to compute")
            }
            var r = BigInt(1)
            if n > 1 { for k in 2...n { r = r * BigInt(k) } }
            return .q(Quantity(.exact(Rational(r))))
        case "%", "‰":
            guard case .q(let q) = v, q.isPlain else { throw EvalError.silent }
            return .q(Quantity(q.value, [UnitPow(unit: op == "%" ? Units.percent : Units.permille, power: 1)]))
        case "ago":
            guard case .q(let q) = v, q.dim == .time else { throw EvalError.silent }
            return try shift(today(), q, sign: -1)
        default:
            throw EvalError.silent
        }
    }

    // MARK: Functions

    func plainArg(_ args: [Node], _ i: Int = 0) throws -> Num {
        guard i < args.count, case .q(let q) = try eval(args[i]) else { throw EvalError.silent }
        guard q.isPlain || q.isPercent else {
            throw EvalError.show(nb ? "Trenger et tall uten enhet" : "Needs a plain number")
        }
        return q.isPercent ? q.value * q.units[0].unit.factor : q.value
    }

    func call(_ name: String, _ args: [Node]) throws -> Value {
        func q(_ i: Int) throws -> Quantity {
            guard i < args.count, case .q(let x) = try eval(args[i]) else { throw EvalError.silent }
            return x
        }
        func real(_ d: Double) throws -> Value {
            guard d.isFinite else { throw EvalError.show(nb ? "Udefinert" : "Undefined") }
            return .q(Quantity(.approx(abs(d) < 1e-15 ? 0 : d)))
        }
        switch name {
        case "id":
            return try eval(args[0])
        case "sqrt", "cbrt", "root":
            var x = try q(0)
            var n = name == "cbrt" ? 3 : 2
            if name == "root", args.count > 1, let k = try plainArg(args, 1).int, k > 0 { n = k }
            if x.isNegative(n) { throw EvalError.show(nb ? "Ingen reell løsning" : "No real result") }
            guard x.units.allSatisfy({ $0.power % n == 0 }) else {
                throw EvalError.show(
                    nb ? "Kan ikke ta roten av \(describe(x.units))" : "Can't take the root of \(describe(x.units))"
                )
            }
            if let r = x.value.rational, let exact = Num.exactRoot(Rational(r.num.magnitude, r.den), n) {
                x.value = r.num.negative ? -Num.exact(exact) : .exact(exact)
            } else {
                let d = x.value.double
                x.value = .approx(
                    n == 2
                        ? d.squareRoot()
                        : (d < 0 ? -Foundation.pow(-d, 1 / Double(n)) : Foundation.pow(d, 1 / Double(n)))
                )
            }
            x.units = x.units.map { UnitPow(unit: $0.unit, power: $0.power / n) }
            return .q(x)
        case "sin", "cos", "tan":
            let x = try q(0)
            var rad: Double
            if x.isPlain {
                rad = x.value.double
            } else if x.dim == .angle {
                if x.units.count == 1, x.units[0].unit.id == "deg", let r = x.value.rational,
                    case .exact(let m) = Num.exact(r / Rational(90)), m.isInteger
                {
                    // Multiples of 90° exactly.
                    let k = ((m.num % BigInt(4)).int! + 4) % 4
                    let s = [0, 1, 0, -1][k]
                    let c = [1, 0, -1, 0][k]
                    switch name {
                    case "sin": return .q(Quantity(Num(s)))
                    case "cos": return .q(Quantity(Num(c)))
                    default:
                        if c == 0 {
                            throw EvalError.show(
                                nb ? "tan er udefinert her" : "tan is undefined at \(Format.canonical(x.value))°"
                            )
                        }
                        return .q(Quantity(.zero))
                    }
                }
                rad = try convertQ(x, to: [UnitPow(unit: Units.radian, power: 1)]).value.double
            } else {
                throw EvalError.show(
                    nb ? "\(name) trenger en vinkel eller et tall" : "\(name) needs an angle or a plain number"
                )
            }
            switch name {
            case "sin": return try real(sin(rad))
            case "cos": return try real(cos(rad))
            default:
                if abs(cos(rad)) < 1e-12 { throw EvalError.show(nb ? "tan er udefinert her" : "tan is undefined here") }
                return try real(tan(rad))
            }
        case "asin", "arcsin": return try real(asin(try plainArg(args).double))
        case "acos", "arccos": return try real(acos(try plainArg(args).double))
        case "atan", "arctan": return try real(atan(try plainArg(args).double))
        case "sinh": return try real(sinh(try plainArg(args).double))
        case "cosh": return try real(cosh(try plainArg(args).double))
        case "tanh": return try real(tanh(try plainArg(args).double))
        case "ln", "log", "log10", "log2":
            let x = try plainArg(args)
            if x.isZero { throw EvalError.show(nb ? "log av 0 er udefinert" : "log of 0 is undefined") }
            if x.isNegative { throw EvalError.show(nb ? "Ingen reell løsning" : "No real result") }
            var base: Double? = name == "ln" ? nil : (name == "log2" ? 2 : 10)
            if name == "log", args.count > 1 { base = try plainArg(args, 1).double }
            // Exact powers of the base: log(100) = 2.
            if let b = base, let bi = Int(exactly: b), let r = x.rational, r.isInteger {
                var p = BigInt(1)
                var k = 0
                while p < r.num && k < 4000 {
                    p = p * BigInt(bi)
                    k += 1
                }
                if p == r.num { return .q(Quantity(Num(k))) }
            }
            let d = x.double
            let v = base.map { log(d) / log($0) } ?? log(d)
            return try real(v)
        case "exp": return try real(exp(try plainArg(args).double))
        case "abs":
            var x = try q(0)
            x.value = x.value.abs
            return .q(x)
        case "round", "floor", "ceil", "trunc":
            var x = try q(0)
            let places = args.count > 1 ? (try plainArg(args, 1).int ?? 0) : 0
            let rule: FloatingPointRoundingRule =
                name == "floor"
                ? .down : (name == "ceil" ? .up : (name == "trunc" ? .towardZero : .toNearestOrAwayFromZero))
            x.value = x.value.rounded(rule, places: places)
            return .q(x)
        case "max", "min", "sum", "avg", "average", "mean", "product":
            let xs = try (0..<args.count).map { try q($0) }
            guard let first = xs.first else { throw EvalError.silent }
            for x in xs.dropFirst() where x.dim != first.dim && !(x.isPlain || first.isPlain) {
                throw EvalError.show(
                    nb
                        ? "Blandede enheter: \(unitName(first)) og \(unitName(x))"
                        : "Mixed dimensions: \(unitName(first)) and \(unitName(x))"
                )
            }
            if name == "product" {
                var r = first
                for x in xs.dropFirst() { r = try multiply(r, x) }
                return .q(r)
            }
            if name == "max" || name == "min" {
                var best = first
                for x in xs.dropFirst() {
                    let xv = try convertQ(x, to: best.units).value
                    if name == "max" ? best.value < xv : xv < best.value { best = x }
                }
                return .q(best)
            }
            var total = first
            if let u = first.absoluteTemperature {
                // Average readings in the first reading's scale.
                var s = first.value
                for x in xs.dropFirst() { s = s + (try convertQ(x, to: [UnitPow(unit: u, power: 1)])).value }
                total.value = s
            } else {
                for x in xs.dropFirst() { total = try add(total, x, sign: 1) }
            }
            if name != "sum" { total.value = total.value / Num(xs.count) }
            return .q(total)
        case "gcd", "lcm":
            let xs = try (0..<args.count).map { try requireInt(try q($0)) }
            guard var r = xs.first else { throw EvalError.silent }
            for x in xs.dropFirst() {
                if name == "gcd" {
                    r = BigInt.gcd(r, x)
                } else {
                    let g = BigInt.gcd(r, x)
                    r = g.isZero ? BigInt() : (r * x).magnitude / g
                }
            }
            return .q(Quantity(.exact(Rational(r))))
        case "fact", "factorial":
            return try postfix("!", try eval(args[0]))
        case "rgb":
            guard args.count == 3 else { throw EvalError.silent }
            let parts = try (0..<3).map { try plainArg(args, $0).int ?? -1 }
            guard parts.allSatisfy({ (0...255).contains($0) }) else {
                throw EvalError.show(nb ? "RGB-verdier er 0–255" : "RGB values are 0–255")
            }
            return .text(String(format: "#%02X%02X%02X", parts[0], parts[1], parts[2]))
        default:
            throw EvalError.silent
        }
    }

    // MARK: Conversion

    func convert(_ an: Node, _ target: Target, rate: Node?) throws -> Value {
        // Rate override: "100 nok in usd at 10.5".
        if let rate {
            let r = try eval(rate)
            if case .q(let rq) = r, rq.isPlain, case .q(let src) = try eval(an), src.hasMoney,
                case .units(let ups, _) = target, ups.count == 1, let tc = ups[0].unit.currency,
                let sc = src.singleUnit?.currency, sc != tc
            {
                guard !rq.value.isZero else { throw EvalError.show(nb ? "Divisjon med null" : "Division by zero") }
                // Which way the rate goes: the user's rate has the live rate's magnitude.
                let saved = ctx.rates
                let multiplyRate: Bool
                if saved != nil, let live = try? ratio(src.units, ups), live.double > 1 {
                    multiplyRate = true
                } else {
                    multiplyRate = saved == nil ? sc != "NOK" : false
                }
                usedRates = false
                let base = src.value * (try factor([UnitPow(unit: src.units[0].unit, power: 1)], rates: false))
                let v = multiplyRate ? base * rq.value : base / rq.value
                return .q(Quantity(v / ups[0].unit.factor, ups))
            }
            return try convertValue(try binary("at", an, rate), target, source: an)
        }
        return try convertValue(try eval(an), target, source: an)
    }

    func convertValue(_ v: Value, _ target: Target, source: Node) throws -> Value {
        switch target {
        case .list(let ts):
            let first = try convertValue(v, ts[0], source: source)
            for t in ts.dropFirst() {
                if let alt = try? convertValue(v, t, source: source) { extras.append((alt, label(t))) }
            }
            return first
        case .zone(let z):
            switch v {
            case .instant(let d, _): return .instant(d, z.zone)
            case .clock(let c, let zone, _):
                guard c.h < 24, c.m < 60 else {
                    throw EvalError.show(nb ? "Ugyldig klokkeslett" : "Invalid clock time")
                }
                let from = zone?.zone ?? ctx.timeZone
                return .instant(try instant(c, on: nil, in: from), z.zone)
            case .date(let y, let m, let d):
                return .instant(try makeDate(y, m, d, 0, 0, 0, ctx.timeZone), z.zone)
            default:
                throw EvalError.silent
            }
        case .unix:
            switch v {
            case .instant(let d, _): return .q(Quantity(Num(Int(d.timeIntervalSince1970.rounded()))))
            case .date(let y, let m, let d):
                return .q(Quantity(Num(Int(try makeDate(y, m, d, 0, 0, 0, ctx.timeZone).timeIntervalSince1970))))
            default: throw EvalError.silent
            }
        case .expr(let node):
            return try inExpr(v, node, source: source)
        case .unknown(let w):
            if case .q(let q) = v, !q.isPlain, !q.bare {
                throw EvalError.show(nb ? "Ukjent enhet «\(w)»" : "Unknown unit or currency '\(w)'")
            }
            throw EvalError.silent
        default:
            break
        }
        guard case .q(let q) = v else {
            if case .text(let t) = v, case .radix = target { return .text(t) }
            if case .clock = v, case .units(let ups, _) = target, ups.count == 1, ups[0].unit.dim == .time {
                // "1:30 in minutes"
                if case .clock(let c, _, _) = v {
                    let secs = Num(c.h * 3600 + c.m * 60 + (c.s ?? 0))
                    return .q(try convertQ(Quantity(secs, [UnitPow(unit: Units.second, power: 1)]), to: ups))
                }
            }
            throw EvalError.silent
        }
        switch target {
        case .units(let ups, let factor):
            var src = q
            if src.bare { src.bare = false }
            if src.isPercent { src = Quantity(q.value * q.units[0].unit.factor) }
            if src.isPlain, !Quantity(.one, ups).dim.isNone {
                throw dimMismatch(src, Quantity(.one, ups), adding: false)
            }
            var r = try convertQ(src, to: ups)
            if !factor.equals(.one) {
                r.value = r.value / factor
                r.unitLabel = UnitText.scaled(ups, factor: factor, nb: nb)
            }
            r.delta = q.delta
            if q.delta, let u = ups.first?.unit, u.offset != nil, ups.count == 1, let su = q.singleUnit,
                su.offset != nil
            {
                // "20 C - 15 C in F": the difference, and the difference read as a temperature.
                var reading = Quantity(q.value, q.units)
                reading.delta = false
                if let alt = try? convertQ(reading, to: ups) {
                    extras.append(
                        (
                            .q(alt),
                            nb
                                ? "\(Format.canonical(q.value)) \(su.symbol) som temperatur"
                                : "\(Format.canonical(q.value)) \(su.symbol) as a temperature"
                        )
                    )
                }
            }
            if ups.count == 1, let u = ups.first?.unit, u.id == "yr" || u.id == "mo" || u.id == "d" {
                calendarAlternatives(q, ups[0].unit)
            }
            return .q(r)
        case .multi(let units):
            return .q(try toMixed(q, units))
        case .radix(let r):
            guard q.isPlain, let i = q.value.bigInt else {
                throw EvalError.show(
                    nb
                        ? "Bare hele tall kan vises i base \(r == 16 ? 16 : r)"
                        : "Only whole numbers convert to base \(r > 100 ? r - 100 : r)"
                )
            }
            if r == 10 { return .q(Quantity(.exact(Rational(i)))) }
            let base = r > 100 ? r - 100 : r
            let prefix = base == 16 ? "0x" : (base == 2 ? "0b" : (base == 8 ? "0o" : ""))
            if i.negative {
                let m = i.magnitude
                if m <= BigInt(2).power(31) {
                    extras.append(
                        (
                            .text(prefix + (BigInt(2).power(32) - m).toString(radix: base)),
                            nb ? "32-bit toerkomplement" : "32-bit two's complement"
                        )
                    )
                }
                if m <= BigInt(2).power(63) {
                    extras.append(
                        (
                            .text(prefix + (BigInt(2).power(64) - m).toString(radix: base)),
                            nb ? "64-bit toerkomplement" : "64-bit two's complement"
                        )
                    )
                }
                return .text("-" + prefix + m.toString(radix: base))
            }
            return .text(prefix + i.toString(radix: base))
        case .percent:
            guard q.isPlain || q.isPercent || q.scaledPercent else {
                throw EvalError.show(nb ? "Bare tall kan vises i prosent" : "Only plain numbers convert to %")
            }
            let f = q.isPercent || q.scaledPercent ? q.value * q.units[0].unit.factor : q.value
            return .q(Quantity(f * Num(100), [UnitPow(unit: Units.percent, power: 1)]))
        case .scale(let n, let name):
            guard q.isPlain else { throw EvalError.silent }
            var r = Quantity(q.value / n)
            r.hint = .scale(name)
            return .q(r)
        default:
            throw EvalError.silent
        }
    }

    func label(_ t: Target) -> String {
        if case .units(let ups, _) = t { return describe(ups) }
        return ""
    }

    /// "1 year in days": the other common year and month lengths.
    func calendarAlternatives(_ q: Quantity, _ target: UnitDef) {
        guard q.units.count == 1, let su = q.singleUnit, target.id == "d", let n = q.value.rational else { return }
        if su.id == "yr" {
            extras.append(
                (
                    .q(
                        Quantity(.exact(n * Rational.parse(decimal: "365.2425")!), [UnitPow(unit: Units.day, power: 1)])
                    ), nb ? "gjennomsnittlig gregoriansk år" : "mean Gregorian year"
                )
            )
            extras.append(
                (
                    .q(Quantity(.exact(n * Rational(366)), [UnitPow(unit: Units.day, power: 1)])),
                    nb ? "skuddår" : "leap year"
                )
            )
        } else if su.id == "mo" {
            extras.append(
                (
                    .q(
                        Quantity(
                            .exact(n * Rational.parse(decimal: "30.436875")!),
                            [UnitPow(unit: Units.day, power: 1)]
                        )
                    ), nb ? "gjennomsnittlig gregoriansk måned" : "mean Gregorian"
                )
            )
            extras.append(
                (
                    .q(Quantity(.exact(n * Rational(30)), [UnitPow(unit: Units.day, power: 1)])),
                    nb ? "30-dagers måned" : "30-day month"
                )
            )
        }
    }

    /// "in a year", "in 25 min", "seconds in a day", "9:30 to 17:15".
    func inExpr(_ v: Value, _ node: Node, source: Node) throws -> Value {
        let rv = try eval(node)
        switch (v, rv) {
        case (.clock(let a, let za, _), .clock(let b, let zb, _)):
            guard a.h < 24, b.h < 24, a.m < 60, b.m < 60 else {
                throw EvalError.show(nb ? "Ugyldig klokkeslett" : "Invalid clock time")
            }
            var secs = (b.h * 3600 + b.m * 60 + (b.s ?? 0)) - (a.h * 3600 + a.m * 60 + (a.s ?? 0))
            if secs < 0 { secs += 86400 }
            var q = Quantity(Num(secs), [UnitPow(unit: Units.second, power: 1)])
            q.hint = .duration
            return .q(q)
        case (.q(let l), .q(let r)):
            if l.bare {
                // "seconds in a day", "meters in 10 km"
                return .q(try convertQ(r, to: l.units))
            }
            if r.dim == .time && l.dim == .length {
                // Pace: "5 km in 25 min"
                var pace = try divide(r, l)
                pace = try convertQ(
                    pace,
                    to: [UnitPow(unit: Units.minute, power: 1), UnitPow(unit: l.units[0].unit, power: -1)]
                )
                pace.hint = .pace
                return .q(pace)
            }
            if l.dim.e[2] < 0 && r.dim.e[2] > 0 || r.dim.e[2] > 0 {
                return .q(try multiply(l, r))
            }
            if l.dim == r.dim, !r.isPlain {
                return .q(try convertQ(l, to: r.units))
            }
            throw EvalError.silent
        default:
            throw EvalError.silent
        }
    }

    // MARK: Durations

    func toDuration(_ q: Quantity) -> Quantity {
        guard q.dim == .time, let secs = try? convertQ(q, to: [UnitPow(unit: Units.second, power: 1)]) else { return q }
        var r = secs
        r.hint = .duration
        return r
    }

    /// Splits a quantity over `units` (largest first): 5 ft 10.87 in.
    func toMixed(_ q: Quantity, _ units: [UnitDef]) throws -> Quantity {
        guard let first = units.first else { throw EvalError.silent }
        var r = try convertQ(q, to: [UnitPow(unit: first, power: 1)])
        r.hint = .mixed(units)
        return r
    }

    // MARK: Dates and clocks

    func today() -> Value {
        let c = calendar.dateComponents([.year, .month, .day], from: ctx.now)
        return .date(y: c.year!, m: c.month!, d: c.day!)
    }

    func makeDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int, _ tz: TimeZone) throws -> Date {
        var cal = calendar
        cal.timeZone = tz
        guard (1...12).contains(m) else { throw EvalError.show(nb ? "Ugyldig måned" : "Invalid month") }
        let comps = DateComponents(year: y, month: m, day: 1)
        guard let first = cal.date(from: comps), let range = cal.range(of: .day, in: .month, for: first) else {
            throw EvalError.silent
        }
        guard (1...range.count).contains(d) else {
            let monthName = Resolver.monthLabel(m, ctx.locale)
            throw EvalError.show(
                nb
                    ? "\(monthName) \(y) har \(range.count) dager"
                    : "\(monthName.capitalized) \(y) has \(range.count) days"
            )
        }
        guard h < 24, mi < 60, s < 60 else { throw EvalError.show(nb ? "Ugyldig klokkeslett" : "Invalid clock time") }
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi, second: s))!
    }

    func dateLiteral(_ d: DateLit, zone: ZoneLit?) throws -> Value {
        let y = d.year ?? nextYear(d.month, d.day)
        let tz = zone?.zone ?? ctx.timeZone
        let date = try makeDate(y, d.month, d.day, d.hour ?? 0, d.minute ?? 0, d.second ?? 0, tz)
        if d.hour != nil || zone != nil { return .instant(date, tz) }
        return .date(y: y, m: d.month, d: d.day)
    }

    /// The year of the next occurrence of month/day (today counts).
    func nextYear(_ m: Int, _ d: Int) -> Int {
        let c = calendar.dateComponents([.year, .month, .day], from: ctx.now)
        if (m, d) < (c.month!, c.day!) { return c.year! + 1 }
        return c.year!
    }

    func dateWord(_ w: String) throws -> Value {
        switch w {
        case "today", "idag": return today()
        case "tomorrow", "imorgen":
            return try shift(today(), Quantity(.one, [UnitPow(unit: Units.day, power: 1)]), sign: 1)
        case "yesterday", "igår":
            return try shift(today(), Quantity(.one, [UnitPow(unit: Units.day, power: 1)]), sign: -1)
        case "now", "nå": return .instant(ctx.now, ctx.timeZone)
        default:
            if w.hasPrefix("month:") {
                let p = w.split(separator: ":")
                let m = Int(p[1])!
                let y = Int(p[2])!
                let first = try makeDate(y, m, 1, 0, 0, 0, ctx.timeZone)
                let n = calendar.range(of: .day, in: .month, for: first)!.count
                return .q(Quantity(Num(n), [UnitPow(unit: Units.day, power: 1)]))
            }
            throw EvalError.silent
        }
    }

    func instant(_ c: ClockLit, on date: (Int, Int, Int)?, in tz: TimeZone) throws -> Date {
        var cal = calendar
        cal.timeZone = tz
        let (y, m, d): (Int, Int, Int)
        if let date {
            (y, m, d) = date
        } else {
            let t = cal.dateComponents([.year, .month, .day], from: ctx.now)
            (y, m, d) = (t.year!, t.month!, t.day!)
        }
        return try makeDate(y, m, d, c.h, c.m, c.s ?? 0, tz)
    }

    func onDate(_ a: Value, _ b: Value) throws -> Value {
        if case .q(let q) = a, q.hasMoney {
            throw EvalError.show(nb ? "Ingen valutakurs for den datoen" : "No exchange rate for that date")
        }
        guard case .date(let y, let m, let d) = b else { throw EvalError.silent }
        switch a {
        case .clock(let c, let zone, _):
            let tz = zone?.zone ?? ctx.timeZone
            return .instant(try instant(c, on: (y, m, d), in: tz), tz)
        default:
            throw EvalError.silent
        }
    }

    func secondsOf(_ q: Quantity) throws -> Num {
        try convertQ(q, to: [UnitPow(unit: Units.second, power: 1)]).value
    }

    /// Date ± duration: whole months and years move on the calendar, whole days stay dates.
    func shift(_ date: Value, _ q: Quantity, sign: Int) throws -> Value {
        guard q.dim == .time else { throw EvalError.silent }
        guard case .date(let y, let m, let d) = date else { throw EvalError.silent }
        let start = try makeDate(y, m, d, 0, 0, 0, ctx.timeZone)
        func asDate(_ x: Date) -> Value {
            let c = calendar.dateComponents([.year, .month, .day], from: x)
            return .date(y: c.year!, m: c.month!, d: c.day!)
        }
        if let u = q.singleUnit, u.id == "mo" || u.id == "yr", let n = q.value.int {
            let comp: Calendar.Component = u.id == "mo" ? .month : .year
            return asDate(calendar.date(byAdding: comp, value: sign * n, to: start)!)
        }
        let secs = try secondsOf(q)
        if case .exact(let r) = Num.exact(Rational(1)) / Num(86400) * secs, r.isInteger, let days = r.num.int {
            return asDate(calendar.date(byAdding: .day, value: sign * days, to: start)!)
        }
        return .instant(start.addingTimeInterval(Double(sign) * secs.double), ctx.timeZone)
    }

    func binaryTime(_ op: String, _ a: Value, _ b: Value) throws -> Value {
        switch (op, a, b) {
        case ("+", .clock(let x, nil, _), .clock(let y, nil, _)), ("-", .clock(let x, nil, _), .clock(let y, nil, _)):
            // Two colon values: durations.
            if op == "-" && x.parts == 2 && y.parts == 2 && x.h < 24 && y.h < 24 {
                var secs = (x.h * 3600 + x.m * 60) - (y.h * 3600 + y.m * 60)
                if secs < 0 { secs += 86400 }
                var q = Quantity(Num(secs), [UnitPow(unit: Units.second, power: 1)])
                q.hint = .duration
                return .q(q)
            }
            let long = x.parts == 3 || y.parts == 3
            let xs = colonSeconds(x, long: long)
            let ys = colonSeconds(y, long: long)
            var q = Quantity(Num(op == "+" ? xs + ys : xs - ys), [UnitPow(unit: Units.second, power: 1)])
            q.hint = .colon(seconds: x.parts == 3 || y.parts == 3)
            return .q(q)
        case ("+", .clock(let c, let z, _), .q(let q)), ("-", .clock(let c, let z, _), .q(let q)),
            ("+", .q(let q), .clock(let c, let z, _)):
            guard q.dim == .time else { throw EvalError.silent }
            guard c.h < 24, c.m < 60 else { throw EvalError.show(nb ? "Ugyldig klokkeslett" : "Invalid clock time") }
            let secs = try secondsOf(q)
            guard let s = secs.rounded(.toNearestOrAwayFromZero).int else { throw EvalError.silent }
            var total = c.h * 3600 + c.m * 60 + (c.s ?? 0) + (op == "-" ? -s : s)
            let days = Int((Double(total) / 86400).rounded(.down))
            total -= days * 86400
            let lit = ClockLit(
                h: total / 3600,
                m: (total % 3600) / 60,
                s: c.s == nil && total % 60 == 0 ? nil : total % 60,
                parts: c.parts
            )
            return .clock(lit, zone: z, dayOffset: days)
        case ("+", .date, .q(let q)), ("-", .date, .q(let q)):
            return try shift(a, q, sign: op == "+" ? 1 : -1)
        case ("+", .q(let q), .date):
            return try shift(b, q, sign: 1)
        case ("-", .date(let y1, let m1, let d1), .date(let y2, let m2, let d2)):
            let a1 = try makeDate(y1, m1, d1, 12, 0, 0, ctx.timeZone)
            let a2 = try makeDate(y2, m2, d2, 12, 0, 0, ctx.timeZone)
            let days = calendar.dateComponents([.day], from: a2, to: a1).day!
            return .q(Quantity(Num(days), [UnitPow(unit: Units.day, power: 1)]))
        case ("-", .instant(let x, _), .instant(let y, _)):
            var q = Quantity(.approx(x.timeIntervalSince(y)), [UnitPow(unit: Units.second, power: 1)])
            if let i = Int(exactly: x.timeIntervalSince(y)) { q.value = Num(i) }
            q.hint = .duration
            return .q(q)
        case ("+", .instant(let x, let tz), .q(let q)), ("-", .instant(let x, let tz), .q(let q)):
            guard q.dim == .time else { throw EvalError.silent }
            let s = try secondsOf(q).double
            return .instant(x.addingTimeInterval(op == "+" ? s : -s), tz)
        default:
            throw EvalError.silent
        }
    }

    /// h:mm:ss; a two-part value next to a three-part one is mm:ss.
    func colonSeconds(_ c: ClockLit, long: Bool) -> Int {
        if c.parts == 3 { return c.h * 3600 + c.m * 60 + (c.s ?? 0) }
        return long ? c.h * 60 + c.m : c.h * 3600 + c.m * 60
    }
}

extension Quantity {
    func isNegative(_ root: Int) -> Bool { root % 2 == 0 && value.isNegative }
}
