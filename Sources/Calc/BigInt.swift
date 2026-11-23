/// Arbitrary-precision signed integer: sign and magnitude, little-endian 32-bit limbs.
/// Only what the calculator needs: arithmetic, comparison, gcd, decimal text and bitwise ops on
/// non-negative values.
struct BigInt: Equatable, Hashable, Comparable, CustomStringConvertible, Sendable {
    /// No trailing zero limbs; zero is `[]` and never negative.
    private(set) var mag: [UInt32]
    private(set) var negative: Bool

    init() {
        mag = []
        negative = false
    }

    init(_ v: Int) {
        negative = v < 0
        var m = v.magnitude
        mag = []
        while m > 0 {
            mag.append(UInt32(truncatingIfNeeded: m))
            m >>= 32
        }
    }

    private init(mag: [UInt32], negative: Bool) {
        self.mag = mag
        self.negative = negative
        normalize()
    }

    /// Decimal digits with an optional leading `-`.
    init?(_ s: String) {
        var digits = Substring(s)
        var neg = false
        if digits.hasPrefix("-") {
            neg = true
            digits = digits.dropFirst()
        }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        var r = BigInt()
        var chunk = 0
        var len = 0
        let tens = [1, 10, 100, 1000, 10000, 100_000, 1_000_000, 10_000_000, 100_000_000, 1_000_000_000]
        for ch in digits {
            chunk = chunk * 10 + Int(ch.asciiValue! - 48)
            len += 1
            if len == 9 {
                r = r.mulSmall(UInt32(tens[9])).addSmall(UInt32(chunk))
                chunk = 0
                len = 0
            }
        }
        if len > 0 { r = r.mulSmall(UInt32(tens[len])).addSmall(UInt32(chunk)) }
        r.negative = neg && !r.mag.isEmpty
        self = r
    }

    private mutating func normalize() {
        while let last = mag.last, last == 0 { mag.removeLast() }
        if mag.isEmpty { negative = false }
    }

    var isZero: Bool { mag.isEmpty }
    var signum: Int { mag.isEmpty ? 0 : (negative ? -1 : 1) }
    var magnitude: BigInt { BigInt(mag: mag, negative: false) }
    var limbCount: Int { mag.count }
    var isOdd: Bool { (mag.first ?? 0) & 1 == 1 }

    /// The value as `Int` when it fits.
    var int: Int? {
        if mag.count > 2 { return nil }
        var m: UInt64 = 0
        for (i, l) in mag.enumerated() { m |= UInt64(l) << (32 * UInt64(i)) }
        if negative {
            return m <= UInt64(Int.max) + 1 ? Int(truncatingIfNeeded: 0 &- m) : nil
        }
        return m <= UInt64(Int.max) ? Int(m) : nil
    }

    var double: Double {
        var d = 0.0
        for l in mag.reversed() { d = d * 4_294_967_296.0 + Double(l) }
        return negative ? -d : d
    }

    /// Number of bits in the magnitude.
    var bitWidth: Int {
        guard let last = mag.last else { return 0 }
        return (mag.count - 1) * 32 + (32 - last.leadingZeroBitCount)
    }

    // MARK: Magnitude helpers

    private static func cmpMag(_ a: [UInt32], _ b: [UInt32]) -> Int {
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        for i in stride(from: a.count - 1, through: 0, by: -1) where a[i] != b[i] {
            return a[i] < b[i] ? -1 : 1
        }
        return 0
    }

    private static func addMag(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var r = [UInt32]()
        r.reserveCapacity(max(a.count, b.count) + 1)
        var carry: UInt64 = 0
        for i in 0..<max(a.count, b.count) {
            let s = UInt64(i < a.count ? a[i] : 0) + UInt64(i < b.count ? b[i] : 0) + carry
            r.append(UInt32(truncatingIfNeeded: s))
            carry = s >> 32
        }
        if carry > 0 { r.append(UInt32(carry)) }
        return r
    }

    /// a - b with a >= b.
    private static func subMag(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var r = [UInt32]()
        r.reserveCapacity(a.count)
        var borrow: Int64 = 0
        for i in 0..<a.count {
            var d = Int64(a[i]) - Int64(i < b.count ? b[i] : 0) - borrow
            if d < 0 {
                d += 4_294_967_296
                borrow = 1
            } else {
                borrow = 0
            }
            r.append(UInt32(d))
        }
        while let last = r.last, last == 0 { r.removeLast() }
        return r
    }

    private static func mulMag(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        if a.isEmpty || b.isEmpty { return [] }
        var r = [UInt32](repeating: 0, count: a.count + b.count)
        for i in 0..<a.count {
            var carry: UInt64 = 0
            let ai = UInt64(a[i])
            if ai == 0 { continue }
            for j in 0..<b.count {
                let t = ai * UInt64(b[j]) + UInt64(r[i + j]) + carry
                r[i + j] = UInt32(truncatingIfNeeded: t)
                carry = t >> 32
            }
            var k = i + b.count
            while carry > 0 {
                let t = UInt64(r[k]) + carry
                r[k] = UInt32(truncatingIfNeeded: t)
                carry = t >> 32
                k += 1
            }
        }
        while let last = r.last, last == 0 { r.removeLast() }
        return r
    }

    private func mulSmall(_ m: UInt32) -> BigInt {
        var r = [UInt32]()
        var carry: UInt64 = 0
        for l in mag {
            let t = UInt64(l) * UInt64(m) + carry
            r.append(UInt32(truncatingIfNeeded: t))
            carry = t >> 32
        }
        if carry > 0 { r.append(UInt32(carry)) }
        return BigInt(mag: r, negative: negative)
    }

    private func addSmall(_ a: UInt32) -> BigInt { self + BigInt(Int(a)) }

    /// Divides the magnitude by a single limb; returns quotient magnitude and remainder.
    private static func divSmall(_ a: [UInt32], _ d: UInt32) -> ([UInt32], UInt32) {
        var q = [UInt32](repeating: 0, count: a.count)
        var rem: UInt64 = 0
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            let cur = (rem << 32) | UInt64(a[i])
            q[i] = UInt32(cur / UInt64(d))
            rem = cur % UInt64(d)
        }
        while let last = q.last, last == 0 { q.removeLast() }
        return (q, UInt32(rem))
    }

    private static func shl(_ a: [UInt32], _ s: Int) -> [UInt32] {
        if s == 0 { return a + [0] }
        var r = [UInt32](repeating: 0, count: a.count + 1)
        for i in 0..<a.count {
            r[i] |= a[i] << UInt32(s)
            r[i + 1] = a[i] >> UInt32(32 - s)
        }
        return r
    }

    /// Knuth algorithm D on magnitudes.
    private static func divModMag(_ u: [UInt32], _ v: [UInt32]) -> ([UInt32], [UInt32]) {
        precondition(!v.isEmpty, "division by zero")
        if cmpMag(u, v) < 0 { return ([], u) }
        if v.count == 1 {
            let (q, r) = divSmall(u, v[0])
            return (q, r == 0 ? [] : [r])
        }
        let s = v.last!.leadingZeroBitCount
        var vn = shl(v, s)
        vn.removeLast()
        var un = shl(u, s)
        if un.count == u.count { un.append(0) }
        let n = v.count
        let m = u.count - n
        var q = [UInt32](repeating: 0, count: m + 1)
        let b: UInt64 = 1 << 32
        for j in stride(from: m, through: 0, by: -1) {
            let num = (UInt64(un[j + n]) << 32) | UInt64(un[j + n - 1])
            var qhat = num / UInt64(vn[n - 1])
            var rhat = num % UInt64(vn[n - 1])
            while qhat >= b || qhat * UInt64(vn[n - 2]) > ((rhat << 32) | UInt64(un[j + n - 2])) {
                qhat -= 1
                rhat += UInt64(vn[n - 1])
                if rhat >= b { break }
            }
            var borrow: Int64 = 0
            var carry: UInt64 = 0
            for i in 0..<n {
                let p = qhat * UInt64(vn[i]) + carry
                carry = p >> 32
                let t = Int64(un[i + j]) - borrow - Int64(p & 0xFFFF_FFFF)
                un[i + j] = UInt32(truncatingIfNeeded: t)
                borrow = t < 0 ? 1 : 0
            }
            let t = Int64(un[j + n]) - borrow - Int64(carry)
            un[j + n] = UInt32(truncatingIfNeeded: t)
            if t < 0 {
                qhat -= 1
                var c: UInt64 = 0
                for i in 0..<n {
                    let s2 = UInt64(un[i + j]) + UInt64(vn[i]) + c
                    un[i + j] = UInt32(truncatingIfNeeded: s2)
                    c = s2 >> 32
                }
                un[j + n] = UInt32(truncatingIfNeeded: UInt64(un[j + n]) + c)
            }
            q[j] = UInt32(truncatingIfNeeded: qhat)
        }
        var r = [UInt32](repeating: 0, count: n)
        for i in 0..<n {
            r[i] = s == 0 ? un[i] : (un[i] >> UInt32(s)) | (un[i + 1] << UInt32(32 - s))
        }
        while let last = q.last, last == 0 { q.removeLast() }
        while let last = r.last, last == 0 { r.removeLast() }
        return (q, r)
    }

    // MARK: Arithmetic

    static func + (a: BigInt, b: BigInt) -> BigInt {
        if a.negative == b.negative { return BigInt(mag: addMag(a.mag, b.mag), negative: a.negative) }
        let c = cmpMag(a.mag, b.mag)
        if c == 0 { return BigInt() }
        return c > 0
            ? BigInt(mag: subMag(a.mag, b.mag), negative: a.negative)
            : BigInt(mag: subMag(b.mag, a.mag), negative: b.negative)
    }

    static prefix func - (a: BigInt) -> BigInt { BigInt(mag: a.mag, negative: !a.negative) }
    static func - (a: BigInt, b: BigInt) -> BigInt { a + (-b) }
    static func * (a: BigInt, b: BigInt) -> BigInt {
        BigInt(mag: mulMag(a.mag, b.mag), negative: a.negative != b.negative)
    }

    /// Truncating division: quotient rounds toward zero, remainder has the dividend's sign.
    func quotientAndRemainder(dividingBy d: BigInt) -> (quotient: BigInt, remainder: BigInt) {
        let (q, r) = BigInt.divModMag(mag, d.mag)
        return (BigInt(mag: q, negative: negative != d.negative), BigInt(mag: r, negative: negative))
    }

    static func / (a: BigInt, b: BigInt) -> BigInt { a.quotientAndRemainder(dividingBy: b).quotient }
    static func % (a: BigInt, b: BigInt) -> BigInt { a.quotientAndRemainder(dividingBy: b).remainder }

    static func < (a: BigInt, b: BigInt) -> Bool {
        if a.negative != b.negative { return a.negative }
        let c = cmpMag(a.mag, b.mag)
        return a.negative ? c > 0 : c < 0
    }

    static func gcd(_ a: BigInt, _ b: BigInt) -> BigInt {
        var x = a.magnitude
        var y = b.magnitude
        while !y.isZero { (x, y) = (y, x % y) }
        return x
    }

    func power(_ e: Int) -> BigInt {
        var result = BigInt(1)
        var base = self
        var e = e
        while e > 0 {
            if e & 1 == 1 { result = result * base }
            e >>= 1
            if e > 0 { base = base * base }
        }
        return result
    }

    static func pow10(_ n: Int) -> BigInt { BigInt(10).power(n) }

    // MARK: Bitwise (non-negative operands)

    static func bitAnd(_ a: BigInt, _ b: BigInt) -> BigInt {
        BigInt(mag: zip(a.mag, b.mag).map { $0 & $1 }, negative: false)
    }

    private static func limbwise(_ a: BigInt, _ b: BigInt, _ f: (UInt32, UInt32) -> UInt32) -> BigInt {
        var r = [UInt32]()
        for i in 0..<max(a.mag.count, b.mag.count) {
            let x: UInt32 = i < a.mag.count ? a.mag[i] : 0
            let y: UInt32 = i < b.mag.count ? b.mag[i] : 0
            r.append(f(x, y))
        }
        return BigInt(mag: r, negative: false)
    }

    static func bitOr(_ a: BigInt, _ b: BigInt) -> BigInt { limbwise(a, b) { $0 | $1 } }
    static func bitXor(_ a: BigInt, _ b: BigInt) -> BigInt { limbwise(a, b) { $0 ^ $1 } }

    // MARK: Text

    var description: String { toString(radix: 10, uppercase: false) }

    func toString(radix: Int, uppercase: Bool = true) -> String {
        if mag.isEmpty { return "0" }
        let chars = Array(uppercase ? "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ" : "0123456789abcdefghijklmnopqrstuvwxyz")
        // Largest power of the radix that fits in a limb.
        var chunkDiv: UInt32 = UInt32(radix)
        var chunkLen = 1
        while UInt64(chunkDiv) * UInt64(radix) <= UInt64(UInt32.max) {
            chunkDiv *= UInt32(radix)
            chunkLen += 1
        }
        var parts: [String] = []
        var cur = mag
        while !cur.isEmpty {
            let (q, r) = BigInt.divSmall(cur, chunkDiv)
            var r2 = r
            var s = ""
            for _ in 0..<chunkLen {
                s.append(chars[Int(r2 % UInt32(radix))])
                r2 /= UInt32(radix)
            }
            parts.append(String(s.reversed()))
            cur = q
        }
        var out = parts.reversed().joined()
        while out.count > 1 && out.hasPrefix("0") { out.removeFirst() }
        return (negative ? "-" : "") + out
    }

    /// Parses digits in `radix` (2…36); underscores are skipped.
    init?(digits: Substring, radix: Int) {
        var r = BigInt()
        var any = false
        for ch in digits {
            if ch == "_" { continue }
            guard let v = ch.hexDigitValue ?? BigInt.base36(ch), v < radix else { return nil }
            r = r.mulSmall(UInt32(radix)) + BigInt(v)
            any = true
        }
        guard any else { return nil }
        self = r
    }

    private static func base36(_ ch: Character) -> Int? {
        guard let a = ch.lowercased().first?.asciiValue, a >= 97, a <= 122 else { return nil }
        return Int(a) - 87
    }
}
