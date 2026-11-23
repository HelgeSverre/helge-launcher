import Foundation

/// Exact rational with a positive denominator, always in lowest terms.
struct Rational: Equatable, Hashable, Sendable {
    let num: BigInt
    let den: BigInt

    init(_ n: BigInt, _ d: BigInt = BigInt(1)) {
        precondition(!d.isZero)
        var n = n
        var d = d
        if d.negative {
            n = -n
            d = -d
        }
        let g = BigInt.gcd(n, d)
        if !g.isZero && g != BigInt(1) {
            n = n / g
            d = d / g
        }
        num = n
        den = d
    }

    init(_ i: Int) { self.init(BigInt(i)) }
    init(_ n: Int, _ d: Int) { self.init(BigInt(n), BigInt(d)) }

    var isInteger: Bool { den == BigInt(1) }
    var isZero: Bool { num.isZero }
    var double: Double {
        let nb = num.bitWidth
        let db = den.bitWidth
        if nb < 1000 && db < 1000 { return num.double / den.double }
        // Scale both down to keep the quotient finite.
        let shift = max(0, min(nb, db) - 900)
        let s = BigInt(2).power(shift)
        return (num / s).double / (den / s).double
    }

    static func + (a: Rational, b: Rational) -> Rational {
        if a.den == b.den { return Rational(a.num + b.num, a.den) }
        return Rational(a.num * b.den + b.num * a.den, a.den * b.den)
    }
    static func - (a: Rational, b: Rational) -> Rational { a + Rational(-b.num, b.den) }
    static func * (a: Rational, b: Rational) -> Rational { Rational(a.num * b.num, a.den * b.den) }
    static func / (a: Rational, b: Rational) -> Rational { Rational(a.num * b.den, a.den * b.num) }
    static prefix func - (a: Rational) -> Rational { Rational(-a.num, a.den) }

    static func < (a: Rational, b: Rational) -> Bool { a.num * b.den < b.num * a.den }

    /// Total limbs; used to stop runaway growth.
    var size: Int { num.limbCount + den.limbCount }

    /// Parses a plain decimal such as `12`, `0.25` or `1.5e-3`.
    static func parse(decimal s: String) -> Rational? {
        var mantissa = s
        var exp = 0
        if let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            guard let x = Int(s[s.index(after: e)...]) else { return nil }
            exp = x
            mantissa = String(s[..<e])
        }
        var intPart = mantissa
        var frac = ""
        if let dot = mantissa.firstIndex(of: ".") {
            intPart = String(mantissa[..<dot])
            frac = String(mantissa[mantissa.index(after: dot)...])
        }
        if intPart.isEmpty { intPart = "0" }
        guard Swift.abs(exp) < 100_000, let n = BigInt(intPart + frac) ?? (frac.isEmpty ? nil : BigInt(intPart + frac))
        else { return nil }
        let scale = exp - frac.count
        return scale >= 0 ? Rational(n * BigInt.pow10(scale)) : Rational(n, BigInt.pow10(-scale))
    }
}

/// A real number: exact while possible, otherwise a Double.
enum Num: Sendable, CustomStringConvertible {
    case exact(Rational)
    case approx(Double)

    static let zero = Num.exact(Rational(0))
    static let one = Num.exact(Rational(1))

    init(_ i: Int) { self = .exact(Rational(i)) }
    init(_ n: Int, _ d: Int) { self = .exact(Rational(n, d)) }
    init(_ d: Double) { self = .approx(d) }

    /// From a decimal string; exact.
    init?(decimal s: String) {
        guard let r = Rational.parse(decimal: s) else { return nil }
        self = .exact(r)
    }

    var double: Double {
        switch self {
        case .exact(let r): return r.double
        case .approx(let d): return d
        }
    }

    var rational: Rational? {
        if case .exact(let r) = self { return r }
        return nil
    }

    var isExact: Bool { rational != nil }

    var isZero: Bool {
        switch self {
        case .exact(let r): return r.isZero
        case .approx(let d): return d == 0
        }
    }

    var isNegative: Bool {
        switch self {
        case .exact(let r): return r.num.negative
        case .approx(let d): return d < 0
        }
    }

    /// Integer value when exact and whole.
    var bigInt: BigInt? {
        if case .exact(let r) = self, r.isInteger { return r.num }
        if case .approx(let d) = self, d.rounded() == d, Swift.abs(d) < 9e15 { return BigInt(Int(d)) }
        return nil
    }

    var int: Int? { bigInt?.int }

    var description: String { Format.canonical(self) }

    static func + (a: Num, b: Num) -> Num {
        if case .exact(let x) = a, case .exact(let y) = b { return .exact(x + y) }
        return .approx(a.double + b.double)
    }
    static func - (a: Num, b: Num) -> Num {
        if case .exact(let x) = a, case .exact(let y) = b { return .exact(x - y) }
        return .approx(a.double - b.double)
    }
    static func * (a: Num, b: Num) -> Num {
        if case .exact(let x) = a, case .exact(let y) = b { return .exact(x * y) }
        return .approx(a.double * b.double)
    }
    /// Callers check for zero first.
    static func / (a: Num, b: Num) -> Num {
        if case .exact(let x) = a, case .exact(let y) = b { return .exact(x / y) }
        return .approx(a.double / b.double)
    }
    static prefix func - (a: Num) -> Num {
        switch a {
        case .exact(let r): return .exact(-r)
        case .approx(let d): return .approx(-d)
        }
    }

    static func < (a: Num, b: Num) -> Bool {
        if case .exact(let x) = a, case .exact(let y) = b { return x < y }
        return a.double < b.double
    }

    func equals(_ b: Num) -> Bool {
        if case .exact(let x) = self, case .exact(let y) = b { return x == y }
        let d = Swift.abs(double - b.double)
        return d <= 1e-12 * Swift.max(1, Swift.abs(double), Swift.abs(b.double))
    }

    var abs: Num { isNegative ? -self : self }

    /// Too large to keep exact without hurting the keystroke budget.
    var isHuge: Bool {
        if case .exact(let r) = self { return r.size > 1200 }
        return false
    }
}

enum NumError: Error {
    case tooLarge
    case undefined(String)
}

extension Num {
    /// Integer powers stay exact within a size budget; others go through Double.
    func power(_ e: Num) throws -> Num {
        if let r = rational, let ei = e.bigInt {
            guard let n = ei.int, Swift.abs(n) <= 1_000_000 else {
                if r.num.magnitude == BigInt(1) && r.den == BigInt(1) {
                    return r.num.negative && ei.isOdd ? .exact(Rational(-1)) : .one
                }
                if r.isZero { return ei.negative ? .approx(.infinity) : .zero }
                throw NumError.tooLarge
            }
            // Result digits ≈ n·log10(max(|num|, den)).
            let bits = Double(max(r.num.bitWidth, r.den.bitWidth)) * Double(Swift.abs(n))
            if bits > 40_000 { throw NumError.tooLarge }
            if n >= 0 { return .exact(Rational(r.num.power(n), r.den.power(n))) }
            if r.isZero { throw NumError.undefined("Division by zero") }
            return .exact(Rational(r.den.power(-n), r.num.power(-n)))
        }
        // Rational exponent p/q: exact when the q-th root is exact.
        if let r = rational, let er = e.rational, let q = er.den.int, q <= 64, let p = er.num.int {
            if let root = Num.exactRoot(r, q) { return try Num.exact(root).power(Num(p)) }
            if r.num.negative && q % 2 == 1 {
                let v = -Foundation.pow(-r.double, Double(p) / Double(q))
                return .approx(v)
            }
        }
        let b = double
        let x = e.double
        if b < 0 && x.rounded() != x { throw NumError.undefined("No real result") }
        let v = Foundation.pow(b, x)
        if v.isInfinite { throw NumError.tooLarge }
        return .approx(v)
    }

    /// The exact q-th root of a rational, if there is one.
    static func exactRoot(_ r: Rational, _ q: Int) -> Rational? {
        if q == 1 { return r }
        if r.num.negative && q % 2 == 0 { return nil }
        func rootInt(_ b: BigInt) -> BigInt? {
            let m = b.magnitude
            if m.bitWidth > 200 { return nil }
            let guess = Foundation.pow(m.double, 1.0 / Double(q)).rounded()
            for g in [guess - 1, guess, guess + 1] where g >= 0 {
                let bi = BigInt(String(format: "%.0f", g))!
                if bi.power(q) == m { return b.negative ? -bi : bi }
            }
            return nil
        }
        guard let n = rootInt(r.num), let d = rootInt(r.den) else { return nil }
        return Rational(n, d)
    }

    func sqrt() throws -> Num {
        if isNegative { throw NumError.undefined("No real result") }
        if let r = rational, let root = Num.exactRoot(r, 2) { return .exact(root) }
        return .approx(double.squareRoot())
    }

    func rounded(_ rule: FloatingPointRoundingRule, places: Int = 0) -> Num {
        if let r = rational {
            let scale = Rational(BigInt.pow10(Swift.max(0, places)))
            let x = r * scale
            let (q, rem) = x.num.quotientAndRemainder(dividingBy: x.den)
            var i = q
            if !rem.isZero {
                let neg = x.num.negative
                switch rule {
                case .down: if neg { i = i - BigInt(1) }
                case .up: if !neg { i = i + BigInt(1) }
                case .towardZero: break
                default:
                    // Half away from zero.
                    let twice = rem.magnitude * BigInt(2)
                    if !(twice < x.den) { i = neg ? i - BigInt(1) : i + BigInt(1) }
                }
            }
            return .exact(Rational(i) / scale)
        }
        let s = Foundation.pow(10, Double(places))
        return .approx((double * s).rounded(rule == .toNearestOrEven ? .toNearestOrAwayFromZero : rule) / s)
    }
}
