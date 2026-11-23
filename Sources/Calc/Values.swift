import Foundation

/// How a quantity prefers to be shown.
enum Hint: Equatable {
    case none
    /// Split over several units: "3 h 15 min", "5 ft 10.87 in".
    case mixed([UnitDef])
    /// A duration derived from other units: shown as h/min/s.
    case duration
    /// "2:15:00" / "1:45".
    case colon(seconds: Bool)
    /// m:ss per distance: "5:00 min/km".
    case pace
    /// "12 dozen", "1000 k".
    case scale(String)

    static func == (a: Hint, b: Hint) -> Bool {
        switch (a, b) {
        case (.none, .none), (.duration, .duration), (.pace, .pace): return true
        case (.mixed(let x), .mixed(let y)): return x == y
        case (.colon(let x), .colon(let y)): return x == y
        case (.scale(let x), .scale(let y)): return x == y
        default: return false
        }
    }
}

struct Quantity {
    var value: Num
    var units: [UnitPow] = []
    /// A bare unit used as an operand ("km" in "km m", "seconds in a day").
    var bare = false
    /// A temperature difference rather than a reading.
    var delta = false
    /// A percentage that came from scaling ("10% * 2"): added as a percent, shown as a number.
    var scaledPercent = false
    /// Units came out of cancellation rather than being typed.
    var derived = false
    var hint = Hint.none
    /// Replaces the unit text, e.g. "L/100 km".
    var unitLabel: String? = nil

    init(_ v: Num, _ units: [UnitPow] = []) {
        value = v
        self.units = units
    }

    var dim: Dim { units.reduce(Dim.none) { $0 + $1.unit.dim * $1.power } }
    var isPlain: Bool { units.isEmpty }
    var isPercent: Bool {
        units.count == 1 && (units[0].unit.id == "%" || units[0].unit.id == "‰") && units[0].power == 1
    }
    /// A single °C/°F/K reading.
    var absoluteTemperature: UnitDef? {
        guard !delta, units.count == 1, units[0].power == 1, units[0].unit.dim == .temperature else { return nil }
        return units[0].unit
    }
    var singleUnit: UnitDef? { units.count == 1 && units[0].power == 1 ? units[0].unit : nil }
    var hasMoney: Bool { units.contains { $0.unit.currency != nil } }
}

enum Value {
    case q(Quantity)
    case date(y: Int, m: Int, d: Int)
    case instant(Date, TimeZone)
    /// Time of day (or a colon duration); `zone` set when written with one.
    case clock(ClockLit, zone: ZoneLit?, dayOffset: Int)
    case bool(Bool)
    case text(String)

    var quantity: Quantity? {
        if case .q(let q) = self { return q }
        return nil
    }
}

struct EvalError: Error {
    var message: String?
    /// Silent errors mean "not a calculation"; visible ones are shown.
    var visible: Bool { message != nil }

    static let silent = EvalError(message: nil)
    static func show(_ m: String) -> EvalError { EvalError(message: m) }
}
