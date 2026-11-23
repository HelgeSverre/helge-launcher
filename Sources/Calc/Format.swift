import Foundation

/// Number text. `canonical` is locale-free (tests, copy raw); `display` is for people.
enum Format {
    /// Significant digits of |x| rounded to `n`, and the decimal exponent of the first digit.
    static func significant(_ x: Num, _ digits: Int = 10) -> (digits: String, exp: Int, negative: Bool)? {
        switch x {
        case .approx(let d):
            guard d.isFinite else { return nil }
            if d == 0 { return ("0", 0, false) }
            let s = String(format: "%.\(digits - 1)e", Swift.abs(d))
            let parts = s.split(separator: "e")
            return (parts[0].replacingOccurrences(of: ".", with: ""), Int(parts[1]) ?? 0, d < 0)
        case .exact(let r):
            if r.isZero { return ("0", 0, false) }
            let n = r.num.magnitude
            let d = r.den
            var e = Int((Double(n.bitWidth - d.bitWidth)) * 0.30102999566)
            let lo = BigInt.pow10(digits - 1)
            let hi = BigInt.pow10(digits)
            for _ in 0..<6 {
                // q = round(|r| · 10^(digits-1-e)) without building rationals (no gcd on big numbers).
                let shift = digits - 1 - e
                let (num, den) = shift >= 0 ? (n * BigInt.pow10(shift), d) : (n, d * BigInt.pow10(-shift))
                let (q0, rem) = num.quotientAndRemainder(dividingBy: den)
                let q = (rem * BigInt(2) < den) ? q0 : q0 + BigInt(1)
                if q < lo {
                    e -= 1
                } else if !(q < hi) {
                    if q == hi { return ("1" + String(repeating: "0", count: digits - 1), e + 1, r.num.negative) }
                    e += 1
                } else {
                    return (q.description, e, r.num.negative)
                }
            }
            return nil
        }
    }

    /// `.` decimal, no grouping, 10 significant digits; exact integers up to 40 digits in full.
    static func canonical(_ x: Num) -> String {
        if case .exact(let r) = x, r.isInteger, r.num.magnitude < BigInt.pow10(40) { return r.num.description }
        guard let (digits, e, neg) = significant(x) else {
            return x.double.isNaN ? "NaN" : (x.double < 0 ? "-∞" : "∞")
        }
        var d = digits
        while d.count > 1 && d.hasSuffix("0") { d.removeLast() }
        let sign = neg ? "-" : ""
        if e > 20 || e < -9 {
            let mant = d.count > 1 ? "\(d.first!).\(d.dropFirst())" : d
            return "\(sign)\(mant)e\(e)"
        }
        return sign + place(d, e)
    }

    /// Digits `d` (first digit at 10^e) as positional text.
    private static func place(_ d: String, _ e: Int) -> String {
        if e < 0 { return "0." + String(repeating: "0", count: -e - 1) + d }
        if d.count <= e + 1 { return d + String(repeating: "0", count: e + 1 - d.count) }
        let i = d.index(d.startIndex, offsetBy: e + 1)
        return String(d[..<i]) + "." + String(d[i...])
    }

    /// People-facing number: grouped digits, locale decimal mark, at most `maxFraction` decimals
    /// (nil: 10 significant digits).
    static func display(_ x: Num, locale: CalcLocale, maxFraction: Int? = nil) -> String {
        var text: String
        if let f = maxFraction, let (digits, e, neg) = significant(x.rounded(.toNearestOrAwayFromZero, places: f), 30) {
            var d = digits
            while d.count > 1 && d.hasSuffix("0") { d.removeLast() }
            text = (neg ? "-" : "") + place(d, e)
            if e > 20 { text = canonical(x) }
        } else if x.abs < Num(1) || !(x.abs < Num(decimal: "1e21")!) {
            text = canonical(x)
        } else {
            // Six decimals are enough to read; Copy Number keeps all ten digits.
            text = canonical(x.rounded(.toNearestOrAwayFromZero, places: 6))
        }
        if text.contains("∞") { return text }
        if let e = text.firstIndex(of: "e") {
            let sup: [Character: Character] = [
                "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
                "-": "⁻",
            ]
            let mant = localizeMark(String(text[..<e]), locale)
            let exp = String(text[text.index(after: e)...].compactMap { sup[$0] })
            return mant.replacingOccurrences(of: "-", with: "−") + " × 10" + exp
        }
        var neg = false
        if text.hasPrefix("-") {
            neg = true
            text.removeFirst()
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        var intPart = String(parts[0])
        let frac = parts.count > 1 ? String(parts[1]) : ""
        if intPart.count > 4 || (intPart.count == 4 && locale.groupFourDigits) {
            var grouped = ""
            for (i, ch) in intPart.reversed().enumerated() {
                if i > 0 && i % 3 == 0 { grouped.append(locale.groupSeparator) }
                grouped.append(ch)
            }
            intPart = String(grouped.reversed())
        }
        return (neg ? "−" : "") + intPart + (frac.isEmpty ? "" : String(locale.decimalMark) + frac)
    }

    private static func localizeMark(_ s: String, _ locale: CalcLocale) -> String {
        locale.decimalMark == "." ? s : s.replacingOccurrences(of: ".", with: String(locale.decimalMark))
    }
}
