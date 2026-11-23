import Foundation

/// Unit lists as text: "kg·m²/s³", "km/h", "USD/week".
enum UnitText {
    static func power(_ p: Int) -> String {
        switch p {
        case 1: return ""
        case 2: return "²"
        case 3: return "³"
        default: return "^\(p)"
        }
    }

    static func name(_ u: UnitDef, compound: Bool, nb: Bool) -> String {
        if compound, let w = nb ? u.wordsNb ?? u.words : u.words { return w.0 }
        return u.symbol
    }

    static func text(_ ups: [UnitPow], nb: Bool) -> String {
        let compound = ups.count > 1 || ups.contains { $0.power != 1 }
        let num = ups.filter { $0.power > 0 }.map { name($0.unit, compound: compound, nb: nb) + power($0.power) }
        let den = ups.filter { $0.power < 0 }.map { "/" + name($0.unit, compound: compound, nb: nb) + power(-$0.power) }
        return num.joined(separator: "·") + den.joined()
    }

    /// "L/100 km": a target with a number in it.
    static func scaled(_ ups: [UnitPow], factor: Num, nb: Bool) -> String {
        let num = ups.filter { $0.power > 0 }.map { name($0.unit, compound: true, nb: nb) + power($0.power) }
        let den = ups.filter { $0.power < 0 }.map { name($0.unit, compound: true, nb: nb) + power(-$0.power) }
        let n = Format.canonical(Num.one / factor)
        return num.joined(separator: "·") + "/" + n + " " + den.joined(separator: "/")
    }
}

/// Final shaping and text for values.
struct Output {
    let ev: Evaluator
    /// Rounding for reading rather than copying.
    var forPeople = false
    var nb: Bool { ev.nb }

    /// Applies display preferences to an untargeted quantity.
    func normalize(_ q: Quantity) -> Quantity {
        var q = q
        if q.scaledPercent && q.isPercent { return Quantity(q.value * q.units[0].unit.factor) }
        if q.unitLabel != nil || q.hint != .none { return q }
        // Units that cancel to a plain number.
        if !q.units.isEmpty && q.dim.isNone && !q.isPercent && q.derived, let f = try? ev.factor(q.units, rates: true) {
            return Quantity(q.value * f)
        }
        // W·h → Wh, also with other time units and inside a rate (kW·h/day → kWh/day).
        if let wi = q.units.firstIndex(where: {
            $0.power == 1 && $0.unit.dim == Units.power && $0.unit.symbol.hasSuffix("W")
        }),
            let ti = q.units.firstIndex(where: { $0.power == 1 && $0.unit.dim == .time }),
            let c = Units.lookup(String(q.units[wi].unit.symbol.dropLast()) + "Wh", norwegian: false),
            case .unit(let u) = c.options[0].reading,
            let f = try? ev.ratio([q.units[ti]], [UnitPow(unit: Units.hour, power: 1)])
        {
            var r = q
            r.value = q.value * f
            r.units = q.units.enumerated().compactMap { i, up in
                i == ti ? nil : (i == wi ? UnitPow(unit: u, power: 1) : up)
            }
            return normalize(r)
        }
        // Energy in a readable size: 394 200 Wh → 394,2 kWh.
        if q.units.count == 1, q.units[0].power == 1, q.units[0].unit.id.hasSuffix("Wh"), !q.value.isZero {
            let family: [UnitDef] = ["Wh", "kWh", "MWh", "GWh", "TWh"].compactMap { id in
                guard let c = Units.lookup(id, norwegian: false), case .unit(let u) = c.options[0].reading else {
                    return nil
                }
                return u
            }
            let sized = family.compactMap { u in try? ev.convertQ(q, to: [UnitPow(unit: u, power: 1)]) }
            if let best = sized.last(where: { !($0.value.abs < Num(1)) }) ?? sized.first,
                best.units[0].unit.id != q.units[0].unit.id
            {
                return best
            }
        }
        // V·A → W, W/V → A, V/Ω → A (only with volts, amperes or ohms present).
        if q.units.count >= 2 {
            let electrical = [Units.watt, Units.ampere, Units.volt, Units.ohm]
            let hasElectrical = q.units.contains { up in
                [Units.ampere, Units.volt, Units.ohm].contains { $0.dim == up.unit.dim }
            }
            if hasElectrical, let target = electrical.first(where: { $0.dim == q.dim }),
                let c = try? ev.convertQ(q, to: [UnitPow(unit: target, power: 1)])
            {
                return c
            }
        }
        // Compound units of one plain kind: kW·h·K/kJ → K.
        if q.units.count > 1, q.dim.complexity == 1, q.dim != .time, let idx = q.dim.e.firstIndex(of: 1) {
            let base: [UnitDef?] = [
                Units.metre, Units.prefixed(Units.gram, Units.siPrefixes.first { $0.sym == "k" }!), nil, Units.ampere,
                Units.kelvin, nil, nil, Units.radian, Units.byte, Units.currency("NOK"), Units.pixel,
            ]
            if let u = q.units.first(where: { $0.unit.dim == q.dim && $0.power == 1 && $0.unit.offset == nil })?.unit
                ?? base[idx],
                var c = try? ev.convertQ(q, to: [UnitPow(unit: u, power: 1)])
            {
                c.delta = q.delta
                return c
            }
        }
        if q.dim == .time {
            let compound = q.units.count > 1 || q.units.first?.power != 1
            if compound || (q.derived && q.units.first?.unit.id == "s") {
                let d = ev.toDuration(q)
                if (try? ev.secondsOf(d))?.double ?? 0 >= 60 { return d }
                return d.units.isEmpty ? q : Quantity(d.value, d.units)
            }
        }
        if q.dim.isNone, q.units.isEmpty { q.hint = .none }
        return q
    }

    struct Text {
        var value: String
        var unit: String?
    }

    /// Locale-free text: "." decimal, no grouping. Used by tests and "copy raw".
    func canonical(_ v: Value, targeted: Bool) -> Text {
        render(v, targeted: targeted, number: { Format.canonical($0) })
    }

    /// People-facing text for the locale.
    func display(_ v: Value, targeted: Bool) -> Text {
        var o = self
        o.forPeople = true
        return o.render(v, targeted: targeted) { n in
            Format.display(n, locale: ev.ctx.locale)
        }
    }

    func render(_ v: Value, targeted: Bool, number: (Num) -> String) -> Text {
        switch v {
        case .q(let q0):
            let q = targeted ? q0 : normalize(q0)
            return quantity(q, number: number)
        case .date(let y, let m, let d):
            return Text(value: String(format: "%04d-%02d-%02d", y, m, d), unit: nil)
        case .instant(let date, let tz):
            let f = ISO8601DateFormatter()
            f.timeZone = tz
            f.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
            var s = f.string(from: date)
            if s.hasSuffix("Z") { s = String(s.dropLast()) + "+00:00" }
            return Text(value: s, unit: nil)
        case .clock(let c, _, _):
            let base = String(format: "%02d:%02d", c.h, c.m)
            return Text(value: c.s.map { base + String(format: ":%02d", $0) } ?? base, unit: nil)
        case .bool(let b):
            return Text(value: b ? (nb ? "sant" : "true") : (nb ? "usant" : "false"), unit: nil)
        case .text(let t):
            return Text(value: t, unit: nil)
        }
    }

    func quantity(_ q: Quantity, number: (Num) -> String) -> Text {
        switch q.hint {
        case .mixed(let units):
            return Text(value: mixed(q, units, number: number, lastPlaces: forPeople ? 2 : 9), unit: nil)
        case .duration:
            let secs = (try? ev.secondsOf(q)) ?? q.value
            let units = [Units.hour, Units.minute, Units.second]
            if secs.abs < Num(60) { return Text(value: number(secs), unit: "s") }
            return Text(
                value: mixed(Quantity(secs, [UnitPow(unit: Units.second, power: 1)]), units, number: number),
                unit: nil
            )
        case .colon(let withSeconds):
            let secs = ((try? ev.secondsOf(q)) ?? q.value).rounded(.toNearestOrAwayFromZero).int ?? 0
            let sign = secs < 0 ? "-" : ""
            let a = abs(secs)
            let text =
                withSeconds
                ? String(format: "%d:%02d:%02d", a / 3600, (a % 3600) / 60, a % 60)
                : String(format: "%d:%02d", a / 3600, (a % 3600) / 60)
            return Text(value: sign + text, unit: nil)
        case .pace:
            let minutes = q.value.double
            var m = Int(minutes)
            var s = Int(((minutes - Double(m)) * 60).rounded())
            if s == 60 {
                m += 1
                s = 0
            }
            return Text(value: String(format: "%d:%02d", m, s), unit: q.unitLabel ?? UnitText.text(q.units, nb: nb))
        case .scale(let name):
            return Text(value: number(q.value), unit: name == "raw" ? nil : name)
        case .none:
            break
        }
        if q.units.isEmpty { return Text(value: number(q.value), unit: nil) }
        if let label = q.unitLabel { return Text(value: number(q.value), unit: label) }
        if q.delta, let u = q.singleUnit, u.id == "°C" || u.id == "K" {
            return Text(value: number(q.value), unit: "K")
        }
        if let u = q.singleUnit, let w = nb ? u.wordsNb ?? u.words : u.words {
            return Text(value: number(q.value), unit: q.value.equals(.one) ? w.0 : w.1)
        }
        return Text(value: number(q.value), unit: UnitText.text(q.units, nb: nb))
    }

    /// "5 ft 10.86614173 in", "1 d 3 h 46 min 40 s"; zero parts are left out.
    func mixed(_ q: Quantity, _ units: [UnitDef], number: (Num) -> String, lastPlaces: Int = 9) -> String {
        let sorted = units.sorted { $0.factor.double > $1.factor.double }
        guard let first = sorted.first,
            var rest = try? ev.convertQ(Quantity(q.value.abs, q.units), to: [UnitPow(unit: first, power: 1)]).value
        else { return number(q.value) }
        var parts: [String] = []
        for (k, u) in sorted.enumerated() {
            if k == sorted.count - 1 {
                if !rest.isZero || parts.isEmpty {
                    parts.append("\(number(rest.rounded(.toNearestOrAwayFromZero, places: lastPlaces))) \(u.symbol)")
                }
                break
            }
            let whole = rest.rounded(.down)
            if !whole.isZero { parts.append("\(number(whole)) \(u.symbol)") }
            let next = sorted[k + 1]
            rest = (rest - whole) * (try! ev.ratio([UnitPow(unit: u, power: 1)], [UnitPow(unit: next, power: 1)]))
        }
        return (q.value.isNegative ? "-" : "") + parts.joined(separator: " ")
    }
}
