import Foundation

/// Exponents over the base dimensions.
struct Dim: Hashable, Sendable {
    static let names = [
        "length", "mass", "time", "current", "temperature", "amount", "luminosity", "angle", "data", "money", "pixel",
    ]
    var e: [Int8]

    init(_ e: [Int8] = Array(repeating: 0, count: 11)) { self.e = e }

    static let none = Dim()
    static func base(_ i: Int) -> Dim {
        var d = Dim()
        d.e[i] = 1
        return d
    }
    static let length = base(0)
    static let mass = base(1)
    static let time = base(2)
    static let current = base(3)
    static let temperature = base(4)
    static let amount = base(5)
    static let angle = base(7)
    static let data = base(8)
    static let money = base(9)
    static let pixel = base(10)

    static func + (a: Dim, b: Dim) -> Dim { Dim(zip(a.e, b.e).map { $0 + $1 }) }
    static func - (a: Dim, b: Dim) -> Dim { Dim(zip(a.e, b.e).map { $0 - $1 }) }
    static func * (a: Dim, p: Int) -> Dim { Dim(a.e.map { $0 * Int8(p) }) }
    static prefix func - (a: Dim) -> Dim { a * -1 }

    var isNone: Bool { e.allSatisfy { $0 == 0 } }
    /// Sum of absolute exponents: how "compound" a dimension is.
    var complexity: Int { e.reduce(0) { $0 + abs(Int($1)) } }

    /// Plain name for error messages: "a length", "a speed".
    var name: String {
        if let n = Dim.named[self] { return n }
        if isNone { return "a plain number" }
        return "a different kind of quantity"
    }

    static let named: [Dim: String] = [
        length: "a length", mass: "a mass", time: "a time", current: "a current", temperature: "a temperature",
        angle: "an angle", data: "a data size", money: "a currency", pixel: "a pixel count",
        length * 2: "an area", length * 3: "a volume", length - time: "a speed", data - time: "a data rate",
        mass + length * 2 - time * 2: "an energy", mass + length * 2 - time * 3: "a power",
        mass + length - time * 2: "a force", mass - length - time * 2: "a pressure", -time: "a frequency",
    ]
}

/// One unit. `factor` converts to SI base units (money: to the currency named by `currency`).
struct UnitDef: Hashable, Sendable {
    let id: String
    let symbol: String
    let dim: Dim
    let factor: Num
    /// Kelvin = value · factor + offset (°C, °F).
    var offset: Num? = nil
    var currency: String? = nil
    /// Shown when this unit is one of several readings ("US gallon").
    var label: String? = nil
    /// Displayed instead of `symbol` when the unit stands alone: ("day", "days").
    var words: (String, String)? = nil
    var wordsNb: (String, String)? = nil

    static func == (a: UnitDef, b: UnitDef) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var isTemperatureScale: Bool { offset != nil }
}

/// What a word can mean.
enum Reading: Sendable {
    case unit(UnitDef)
    /// Multiplier after a number ("10k", "2 million"); as a conversion target it is a unit.
    case scale(Num, String)
}

struct Candidate: Sendable {
    var reading: Reading
    var label: String?
}

/// Every candidate list for a word; `offer` lists the others as alternatives.
struct Choices: Sendable {
    var options: [Candidate]
    var offer: Bool
}

enum Units {
    private static func r(_ s: String) -> Num { Num(decimal: s)! }
    private static let pi = Num.approx(Double.pi)

    // MARK: Definitions

    static let metre = UnitDef(id: "m", symbol: "m", dim: .length, factor: .one)
    static let inch = UnitDef(id: "in", symbol: "in", dim: .length, factor: r("0.0254"))
    static let foot = UnitDef(id: "ft", symbol: "ft", dim: .length, factor: r("0.3048"))
    static let yard = UnitDef(id: "yd", symbol: "yd", dim: .length, factor: r("0.9144"))
    static let mile = UnitDef(id: "mi", symbol: "mi", dim: .length, factor: r("1609.344"), label: "miles")
    static let nmi = UnitDef(id: "nmi", symbol: "nmi", dim: .length, factor: r("1852"))
    static let furlong = UnitDef(id: "furlong", symbol: "furlong", dim: .length, factor: r("201.168"))
    static let lightYear = UnitDef(id: "ly", symbol: "ly", dim: .length, factor: r("9460730472580800"))
    static let au = UnitDef(id: "au", symbol: "au", dim: .length, factor: r("149597870700"))
    static let parsec = UnitDef(id: "pc", symbol: "pc", dim: .length, factor: r("30856775814913673"))
    static let thou = UnitDef(
        id: "thou",
        symbol: "mil",
        dim: .length,
        factor: r("0.0000254"),
        label: "thousandth of an inch"
    )
    static let norskMil = UnitDef(
        id: "mil",
        symbol: "mil",
        dim: .length,
        factor: r("10000"),
        label: "norsk mil (10 km)"
    )
    static let angstrom = UnitDef(id: "Å", symbol: "Å", dim: .length, factor: r("1e-10"))

    static let litre = UnitDef(id: "L", symbol: "L", dim: .length * 3, factor: r("0.001"))
    static let galUS = UnitDef(
        id: "gal",
        symbol: "gal",
        dim: .length * 3,
        factor: r("0.003785411784"),
        label: "US gallon"
    )
    static let galImp = UnitDef(
        id: "galImp",
        symbol: "gal",
        dim: .length * 3,
        factor: r("0.00454609"),
        label: "imperial gallon"
    )
    static let quart = UnitDef(id: "qt", symbol: "qt", dim: .length * 3, factor: r("0.000946352946"))
    static let pintUS = UnitDef(id: "pt", symbol: "pt", dim: .length * 3, factor: r("0.000473176473"), label: "US pint")
    static let pintImp = UnitDef(
        id: "ptImp",
        symbol: "pt",
        dim: .length * 3,
        factor: r("0.00056826125"),
        label: "imperial pint"
    )
    static let cupUS = UnitDef(
        id: "cup",
        symbol: "cup",
        dim: .length * 3,
        factor: r("0.0002365882365"),
        label: "US cup"
    )
    static let cupMetric = UnitDef(
        id: "cupMetric",
        symbol: "cup",
        dim: .length * 3,
        factor: r("0.00025"),
        label: "metric cup"
    )
    static let cupImp = UnitDef(
        id: "cupImp",
        symbol: "cup",
        dim: .length * 3,
        factor: r("0.000284130625"),
        label: "imperial cup"
    )
    static let flOz = UnitDef(
        id: "floz",
        symbol: "fl oz",
        dim: .length * 3,
        factor: r("0.0000295735295625"),
        label: "fluid ounce (US)"
    )
    static let tbspUS = UnitDef(
        id: "tbsp",
        symbol: "tbsp",
        dim: .length * 3,
        factor: r("0.00001478676478125"),
        label: "US tablespoon"
    )
    static let tbspMetric = UnitDef(
        id: "tbspMetric",
        symbol: "tbsp",
        dim: .length * 3,
        factor: r("0.000015"),
        label: "metric tablespoon (15 mL)"
    )
    static let tbspAU = UnitDef(
        id: "tbspAU",
        symbol: "tbsp",
        dim: .length * 3,
        factor: r("0.00002"),
        label: "Australian (20 mL)"
    )
    static let tspUS = UnitDef(
        id: "tsp",
        symbol: "tsp",
        dim: .length * 3,
        factor: r("0.00000492892159375"),
        label: "US teaspoon"
    )
    static let tspMetric = UnitDef(
        id: "tspMetric",
        symbol: "tsp",
        dim: .length * 3,
        factor: r("0.000005"),
        label: "metric teaspoon (5 mL)"
    )
    static let ss = UnitDef(id: "ss", symbol: "ss", dim: .length * 3, factor: r("0.000015"))
    static let ts = UnitDef(id: "ts", symbol: "ts", dim: .length * 3, factor: r("0.000005"))

    static let acre = UnitDef(id: "acre", symbol: "acre", dim: .length * 2, factor: r("4046.8564224"))
    static let hectare = UnitDef(id: "ha", symbol: "ha", dim: .length * 2, factor: r("10000"))
    static let maal = UnitDef(id: "mål", symbol: "mål", dim: .length * 2, factor: r("1000"))

    static let gram = UnitDef(id: "g", symbol: "g", dim: .mass, factor: r("0.001"))
    static let tonne = UnitDef(id: "t", symbol: "t", dim: .mass, factor: r("1000"), label: "metric tonne")
    static let shortTon = UnitDef(
        id: "shortTon",
        symbol: "short ton",
        dim: .mass,
        factor: r("907.18474"),
        label: "US short ton"
    )
    static let longTon = UnitDef(
        id: "longTon",
        symbol: "long ton",
        dim: .mass,
        factor: r("1016.0469088"),
        label: "UK long ton"
    )
    static let pound = UnitDef(id: "lb", symbol: "lb", dim: .mass, factor: r("0.45359237"))
    static let ounce = UnitDef(id: "oz", symbol: "oz", dim: .mass, factor: r("0.028349523125"))
    static let troyOunce = UnitDef(id: "ozt", symbol: "oz t", dim: .mass, factor: r("0.0311034768"))
    static let stone = UnitDef(id: "st", symbol: "st", dim: .mass, factor: r("6.35029318"))
    static let carat = UnitDef(id: "ct", symbol: "ct", dim: .mass, factor: r("0.0002"))
    static let grain = UnitDef(id: "gr", symbol: "gr", dim: .mass, factor: r("0.00006479891"))
    static let stick = UnitDef(id: "stick", symbol: "stick", dim: .mass, factor: r("0.11339809250"))

    static let second = UnitDef(id: "s", symbol: "s", dim: .time, factor: .one)
    static let minute = UnitDef(id: "min", symbol: "min", dim: .time, factor: r("60"))
    static let hour = UnitDef(id: "h", symbol: "h", dim: .time, factor: r("3600"))
    static let day = UnitDef(
        id: "d",
        symbol: "d",
        dim: .time,
        factor: r("86400"),
        words: ("day", "days"),
        wordsNb: ("dag", "dager")
    )
    static let week = UnitDef(
        id: "wk",
        symbol: "wk",
        dim: .time,
        factor: r("604800"),
        words: ("week", "weeks"),
        wordsNb: ("uke", "uker")
    )
    static let fortnight = UnitDef(id: "fortnight", symbol: "fortnight", dim: .time, factor: r("1209600"))
    /// 365/12 days; see `year`.
    static let month = UnitDef(
        id: "mo",
        symbol: "month",
        dim: .time,
        factor: r("2628000"),
        words: ("month", "months"),
        wordsNb: ("måned", "måneder")
    )
    /// 365 days as a plain duration; calendar arithmetic on dates uses real months and years.
    static let year = UnitDef(
        id: "yr",
        symbol: "year",
        dim: .time,
        factor: r("31536000"),
        words: ("year", "years"),
        wordsNb: ("år", "år")
    )
    static let decade = UnitDef(id: "decade", symbol: "decade", dim: .time, factor: r("315360000"))
    static let century = UnitDef(id: "century", symbol: "century", dim: .time, factor: r("3153600000"))

    static let radian = UnitDef(id: "rad", symbol: "rad", dim: .angle, factor: .one)
    static let degree = UnitDef(id: "deg", symbol: "°", dim: .angle, factor: .approx(Double.pi / 180))
    static let turn = UnitDef(id: "turn", symbol: "turn", dim: .angle, factor: .approx(2 * Double.pi))
    static let gradian = UnitDef(id: "grad", symbol: "grad", dim: .angle, factor: .approx(Double.pi / 200))
    static let arcmin = UnitDef(id: "arcmin", symbol: "′", dim: .angle, factor: .approx(Double.pi / 10800))
    static let arcsec = UnitDef(id: "arcsec", symbol: "″", dim: .angle, factor: .approx(Double.pi / 648000))

    static let celsius = UnitDef(id: "°C", symbol: "°C", dim: .temperature, factor: .one, offset: r("273.15"))
    static let fahrenheit = UnitDef(
        id: "°F",
        symbol: "°F",
        dim: .temperature,
        factor: Num(5, 9),
        offset: r("459.67") * Num(5, 9)
    )
    static let kelvin = UnitDef(id: "K", symbol: "K", dim: .temperature, factor: .one)

    static let ampere = UnitDef(id: "A", symbol: "A", dim: .current, factor: .one)
    static let energy = Dim.mass + Dim.length * 2 - Dim.time * 2
    static let power = energy - Dim.time
    static let volt = UnitDef(id: "V", symbol: "V", dim: power - .current, factor: .one)
    static let watt = UnitDef(id: "W", symbol: "W", dim: power, factor: .one)
    static let joule = UnitDef(id: "J", symbol: "J", dim: energy, factor: .one)
    static let newton = UnitDef(id: "N", symbol: "N", dim: .mass + .length - Dim.time * 2, factor: .one)
    static let pascal = UnitDef(id: "Pa", symbol: "Pa", dim: .mass - .length - Dim.time * 2, factor: .one)
    static let hertz = UnitDef(id: "Hz", symbol: "Hz", dim: -Dim.time, factor: .one)
    static let ohm = UnitDef(id: "Ω", symbol: "Ω", dim: power - Dim.current * 2, factor: .one)
    static let wattHour = UnitDef(id: "Wh", symbol: "Wh", dim: energy, factor: r("3600"))
    static let calorie = UnitDef(id: "cal", symbol: "cal", dim: energy, factor: r("4.184"), label: "small calorie")
    static let kcal = UnitDef(id: "kcal", symbol: "kcal", dim: energy, factor: r("4184"), label: "food Calorie (kcal)")
    static let eV = UnitDef(id: "eV", symbol: "eV", dim: energy, factor: r("1.602176634e-19"))
    static let btu = UnitDef(id: "BTU", symbol: "BTU", dim: energy, factor: r("1055.05585262"))
    static let bar = UnitDef(id: "bar", symbol: "bar", dim: pascal.dim, factor: r("100000"))
    static let atm = UnitDef(id: "atm", symbol: "atm", dim: pascal.dim, factor: r("101325"))
    static let psi = UnitDef(id: "psi", symbol: "psi", dim: pascal.dim, factor: r("6894.757293168361"))
    static let mmHg = UnitDef(id: "mmHg", symbol: "mmHg", dim: pascal.dim, factor: r("133.322387415"))
    static let hpMech = UnitDef(
        id: "hp",
        symbol: "hp",
        dim: power,
        factor: r("745.69987158227022"),
        label: "mechanical hp"
    )
    static let hpMetric = UnitDef(
        id: "hk",
        symbol: "hk",
        dim: power,
        factor: r("735.49875"),
        label: "metric hp (hk/PS)"
    )

    static let mph = UnitDef(id: "mph", symbol: "mph", dim: .length - .time, factor: r("0.44704"))
    static let kmh = UnitDef(id: "km/h", symbol: "km/h", dim: .length - .time, factor: Num(5, 18))
    static let knot = UnitDef(id: "kn", symbol: "kn", dim: .length - .time, factor: Num(1852, 3600))
    static let mpgUS = UnitDef(
        id: "mpg",
        symbol: "mpg (US)",
        dim: Dim.length * -2,
        factor: r("1609.344") / r("0.003785411784"),
        label: "US gallon"
    )
    static let mpgImp = UnitDef(
        id: "mpgImp",
        symbol: "mpg (imp)",
        dim: Dim.length * -2,
        factor: r("1609.344") / r("0.00454609"),
        label: "imperial gallon"
    )

    static let bit = UnitDef(id: "bit", symbol: "bit", dim: .data, factor: .one)
    static let byte = UnitDef(id: "B", symbol: "B", dim: .data, factor: r("8"))

    static let pixel = UnitDef(id: "px", symbol: "px", dim: .pixel, factor: .one)
    static let rem = UnitDef(id: "rem", symbol: "rem", dim: .pixel, factor: r("16"))
    static let ppi = UnitDef(id: "ppi", symbol: "ppi", dim: Dim.pixel - .length, factor: Num(1) / r("0.0254"))

    static let percent = UnitDef(id: "%", symbol: "%", dim: .none, factor: Num(1, 100))
    static let permille = UnitDef(id: "‰", symbol: "‰", dim: .none, factor: Num(1, 1000))
    static let dozen = UnitDef(id: "dozen", symbol: "dozen", dim: .none, factor: r("12"))
    static let gross = UnitDef(id: "gross", symbol: "gross", dim: .none, factor: r("144"))

    static func currency(_ code: String, factor: Num = .one, symbol: String? = nil, label: String? = nil) -> UnitDef {
        UnitDef(
            id: symbol == nil ? code : code + ":" + symbol!,
            symbol: symbol ?? code,
            dim: .money,
            factor: factor,
            currency: code,
            label: label ?? code
        )
    }

    static let currencyCodes = [
        "NOK", "USD", "EUR", "GBP", "SEK", "DKK", "JPY", "CHF", "CAD", "AUD", "NZD", "CNY", "HKD", "INR", "ISK", "PLN",
        "CZK", "HUF", "KRW", "SGD", "THB", "TRY", "ZAR", "BRL", "MXN", "ILS", "TWD", "PHP", "IDR", "MYR", "RON", "BGN",
        "BTC", "ETH",
    ]

    // MARK: Prefixes

    struct Prefix {
        let sym: String
        let word: String
        let factor: Num
    }

    static let siPrefixes: [Prefix] = [
        Prefix(sym: "p", word: "pico", factor: r("1e-12")), Prefix(sym: "n", word: "nano", factor: r("1e-9")),
        Prefix(sym: "µ", word: "micro", factor: r("1e-6")), Prefix(sym: "μ", word: "micro", factor: r("1e-6")),
        Prefix(sym: "u", word: "micro", factor: r("1e-6")), Prefix(sym: "m", word: "milli", factor: r("1e-3")),
        Prefix(sym: "c", word: "centi", factor: r("1e-2")), Prefix(sym: "d", word: "deci", factor: r("1e-1")),
        Prefix(sym: "h", word: "hecto", factor: r("1e2")), Prefix(sym: "k", word: "kilo", factor: r("1e3")),
        Prefix(sym: "M", word: "mega", factor: r("1e6")), Prefix(sym: "G", word: "giga", factor: r("1e9")),
        Prefix(sym: "T", word: "tera", factor: r("1e12")), Prefix(sym: "P", word: "peta", factor: r("1e15")),
        Prefix(sym: "E", word: "exa", factor: r("1e18")),
    ]
    static let bigPrefixes = siPrefixes.filter { $0.factor.double >= 1000 }
    static let binaryPrefixes: [Prefix] = [
        Prefix(sym: "Ki", word: "kibi", factor: r("1024")), Prefix(sym: "Mi", word: "mebi", factor: r("1048576")),
        Prefix(sym: "Gi", word: "gibi", factor: r("1073741824")),
        Prefix(sym: "Ti", word: "tebi", factor: r("1099511627776")),
        Prefix(sym: "Pi", word: "pebi", factor: r("1125899906842624")),
    ]

    static func prefixed(_ u: UnitDef, _ p: Prefix) -> UnitDef {
        let sym = (p.sym == "μ" || p.sym == "u" ? "µ" : p.sym) + u.symbol
        return UnitDef(id: sym, symbol: sym, dim: u.dim, factor: p.factor * u.factor)
    }

    // MARK: Lookup tables

    /// Case-sensitive words → choices.
    nonisolated(unsafe) private(set) static var exact: [String: Choices] = [:]
    /// Lowercased words (long names and explicit lowercase aliases).
    nonisolated(unsafe) private(set) static var folded: [String: Choices] = [:]
    /// Norwegian-only words; checked first in Norwegian.
    nonisolated(unsafe) private(set) static var norwegian: [String: Choices] = [:]
    /// Units by symbol, for targets and display lookups.
    nonisolated(unsafe) private(set) static var bySymbol: [String: UnitDef] = [:]

    private static let built: Bool = {
        build()
        return true
    }()

    static func ensureBuilt() { _ = built }

    private static func one(_ u: UnitDef, _ label: String? = nil) -> Choices {
        Choices(options: [Candidate(reading: .unit(u), label: label)], offer: false)
    }

    private static func add(_ words: [String], _ c: Choices, folded fold: Bool = true) {
        for w in words {
            if exact[w] == nil { exact[w] = c }
            if fold && w.count >= 3 && folded[w.lowercased()] == nil { folded[w.lowercased()] = c }
        }
    }

    private static func add(_ words: [String], _ u: UnitDef, folded fold: Bool = true) {
        add(words, one(u), folded: fold)
        bySymbol[u.symbol] = bySymbol[u.symbol] ?? u
    }

    private static func offer(_ units: [UnitDef]) -> Choices {
        Choices(options: units.map { Candidate(reading: .unit($0), label: $0.label) }, offer: true)
    }

    private static func fallback(_ units: [UnitDef]) -> Choices {
        Choices(options: units.map { Candidate(reading: .unit($0), label: $0.label) }, offer: false)
    }

    /// SI-prefixed symbols (`km`) and words (`kilometre`).
    private static func addPrefixed(
        _ u: UnitDef,
        names: [String],
        prefixes: [Prefix] = siPrefixes,
        symbols: Bool = true
    ) {
        add([u.symbol] + names, u)
        for p in prefixes {
            let pu = prefixed(u, p)
            if symbols { add([p.sym + u.symbol], pu, folded: false) }
            add(names.map { p.word + $0 }, pu)
        }
    }

    private static func build() {
        // Length
        addPrefixed(metre, names: ["metre", "metres", "meter", "meters"])
        add(["inch", "inches", "tomme", "tommer", "\""], inch)
        add(["ft", "foot", "feet", "fot", "'"], foot)
        add(["yd", "yard", "yards"], yard)
        add(["mi", "mile", "miles"], mile)
        add(["nmi", "nautical mile", "nautical miles", "nm_naut"], nmi)
        add(["furlong", "furlongs"], furlong)
        add(["ly", "light year", "light years", "lightyear", "lightyears", "lysår"], lightYear)
        add(["au", "AU", "astronomical unit", "astronomical units"], au)
        add(["pc", "parsec", "parsecs"], parsec)
        add(["thou"], thou)
        add(["Å", "angstrom", "ångström"], angstrom)
        // `mil` depends on the language; see `lookup`.

        // Area and volume
        add(["acre", "acres"], acre)
        add(["ha", "hectare", "hectares", "hektar"], hectare)
        add(["mål", "dekar", "dekares"], maal)
        let litreNames = ["litre", "litres", "liter", "liters", "l", "L"]
        add(litreNames, litre)
        for p in siPrefixes where ["m", "c", "d", "h", "k", "µ"].contains(p.sym) {
            let pu = prefixed(litre, p)
            add([p.sym + "L", p.sym + "l"], pu, folded: false)
            add(["litre", "litres", "liter", "liters"].map { p.word + $0 }, pu)
        }
        add(["gallon", "gallons", "gal"], offer([galUS, galImp]))
        add(["imperial gallon", "imperial gallons"], galImp)
        add(["quart", "quarts", "qt"], quart)
        add(["pint", "pints", "pt"], offer([pintUS, pintImp]))
        add(["cup", "cups", "kopp", "kopper"], offer([cupUS, cupMetric, cupImp]))
        add(["fl oz", "floz", "fluid ounce", "fluid ounces", "fl. oz"], flOz)
        add(["tbsp", "tablespoon", "tablespoons", "tbs", "Tbsp"], offer([tbspUS, tbspMetric, tbspAU]))
        add(["tsp", "teaspoon", "teaspoons"], offer([tspUS, tspMetric]))
        add(["stick", "sticks", "stick of butter", "sticks of butter"], stick)

        // Mass
        addPrefixed(gram, names: ["gram", "grams", "gramme", "grammes"])
        add(["kilo", "kilos"], prefixed(gram, siPrefixes.first { $0.sym == "k" }!))
        add(["t", "tonne", "tonnes", "metric ton", "metric tons", "tonn"], tonne)
        add(["ton", "tons"], offer([tonne, shortTon, longTon]))
        add(["lb", "lbs"], pound)
        add(["pound", "pounds", "pund"], fallback([pound, currency("GBP", label: "pound sterling")]))
        add(["oz", "ounce", "ounces", "unse"], fallback([ounce, flOz]))
        add(["troy oz", "troy ounce", "troy ounces", "ozt"], troyOunce)
        add(["stone", "stones"], stone)
        add(["carat", "carats", "ct", "karat"], carat)
        add(["grain", "grains"], grain)

        // Time
        add(["s", "sec", "secs", "second", "seconds", "sekund", "sekunder"], second)
        for p in siPrefixes where ["m", "µ", "u", "n", "p"].contains(p.sym) {
            let pu = prefixed(second, p)
            add([p.sym + "s"], pu, folded: false)
            add([p.word + "second", p.word + "seconds"], pu)
        }
        add(["min", "mins", "minute", "minutes", "minutt", "minutter"], minute)
        add(["h", "hr", "hrs", "hour", "hours", "timer"], hour)
        add(["d", "day", "days", "dag", "dager", "døgn", "døgnet"], day)
        add(["wk", "wks", "week", "weeks", "uke", "uker", "uken"], week)
        add(["fortnight", "fortnights"], fortnight)
        add(["mo", "month", "months", "måned", "måneder", "mnd"], month)
        add(["yr", "yrs", "year", "years", "år", "året"], year)
        add(["decade", "decades", "tiår"], decade)
        add(["century", "centuries", "århundre"], century)

        // Angle
        add(["rad", "rads", "radian", "radians"], radian)
        add(["deg", "degree", "degrees", "°"], degree)
        add(["turn", "turns", "rev", "revolution", "revolutions"], turn)
        add(["grad", "gradian", "gradians", "gon"], gradian)
        add(["arcmin", "arcminute", "arcminutes"], arcmin)
        add(["arcsec", "arcsecond", "arcseconds"], arcsec)

        // Temperature (coulomb and farad are left out: C and F are always temperatures)
        add(["°C", "C", "c", "celsius", "degC", "℃", "grader celsius"], celsius)
        add(["°F", "F", "f", "fahrenheit", "degF", "℉"], fahrenheit)
        add(["K", "kelvin", "kelvins"], kelvin)

        // Electricity, energy, power, pressure
        addPrefixed(ampere, names: ["amp", "amps", "ampere", "amperes"])
        addPrefixed(volt, names: ["volt", "volts"])
        addPrefixed(watt, names: ["watt", "watts"])
        addPrefixed(joule, names: ["joule", "joules"])
        addPrefixed(newton, names: ["newton", "newtons"])
        addPrefixed(pascal, names: ["pascal", "pascals"])
        addPrefixed(hertz, names: ["hertz"])
        addPrefixed(ohm, names: ["ohm", "ohms"])
        add(["ohm", "ohms"], ohm)
        for p in siPrefixes where ["k", "M"].contains(p.sym) {
            add([p.sym + "ohm"], prefixed(ohm, p), folded: false)
        }
        addPrefixed(wattHour, names: ["watt hour", "watt hours", "watt-hour", "watt-hours"], prefixes: bigPrefixes)
        add(["cal", "calorie", "calories", "kalori", "kalorier"], offer([calorie, kcal]))
        add(["kcal", "Cal", "kilocalorie", "kilocalories", "kilokalori", "kilokalorier"], kcal)
        addPrefixed(eV, names: ["electronvolt", "electronvolts"], prefixes: bigPrefixes)
        add(["BTU", "btu"], btu)
        add(["bar"], bar)
        add(["mbar", "millibar"], UnitDef(id: "mbar", symbol: "mbar", dim: bar.dim, factor: r("100")))
        add(["atm", "atmosphere", "atmospheres"], atm)
        add(["psi"], psi)
        add(["mmHg"], mmHg)
        add(["hp", "horsepower"], offer([hpMech, hpMetric]))
        add(["hk", "PS", "hestekrefter"], hpMetric)

        // Speed and fuel
        add(["mph"], mph)
        add(["kph", "kmh", "kmph", "km/t"], kmh)
        add(["kn", "kt", "knot", "knots", "knop"], knot)
        add(["mpg"], offer([mpgUS, mpgImp]))

        // Data
        add(["bit", "bits"], bit)
        add(["B", "byte", "bytes"], byte)
        for p in bigPrefixes + binaryPrefixes {
            let b = prefixed(byte, p)
            let t = prefixed(bit, p)
            add([p.sym + "B"], b, folded: false)
            add([p.word + "byte", p.word + "bytes"], b)
            add([p.sym + "bit", p.sym + "bits", p.sym + "b"], t, folded: false)
            add([p.word + "bit", p.word + "bits"], t)
        }
        add(["KB"], prefixed(byte, siPrefixes.first { $0.sym == "k" }!), folded: false)
        let kB = prefixed(byte, siPrefixes.first { $0.sym == "k" }!)
        for p in bigPrefixes where p.sym != "k" {
            let lower = p.sym.lowercased() + "b"
            exact[lower] = Choices(
                options: [
                    Candidate(reading: .unit(prefixed(byte, p)), label: "\(p.word)bytes"),
                    Candidate(reading: .unit(prefixed(bit, p)), label: "\(p.word)bits"),
                ],
                offer: true
            )
        }
        exact["kb"] = Choices(
            options: [
                Candidate(reading: .unit(kB), label: "kilobyte"),
                Candidate(reading: .unit(prefixed(bit, siPrefixes.first { $0.sym == "k" }!)), label: "kilobit"),
            ],
            offer: true
        )
        exact["kB"] = Choices(
            options: [
                Candidate(reading: .unit(kB), label: "SI kilobyte"),
                Candidate(reading: .unit(prefixed(byte, binaryPrefixes[0])), label: "kibibyte (KiB)"),
            ],
            offer: true
        )
        for (sym, p) in [("bps", nil), ("kbps", "k"), ("Mbps", "M"), ("Gbps", "G"), ("Tbps", "T")]
            as [(String, String?)]
        {
            let f = p.map { s in siPrefixes.first { $0.sym == s }!.factor } ?? .one
            let u = UnitDef(id: sym, symbol: sym, dim: Dim.data - .time, factor: f)
            add([sym], u, folded: false)
            exact[sym.lowercased()] = exact[sym.lowercased()] ?? one(u)
        }

        // Screen
        add(["px", "pixel", "pixels", "piksler"], pixel)
        add(["rem", "em"], rem)
        add(["ppi", "dpi"], ppi)

        // Counting
        add(["%", "percent", "per cent", "prosent", "pct"], percent)
        add(["‰", "permille", "promille"], permille)
        add(["dozen", "dozens", "dusin"], dozen)
        add(["gross"], gross)

        // Money
        for code in currencyCodes {
            add([code, code.lowercased()], currency(code), folded: false)
        }
        add(
            ["$", "dollar", "dollars", "dollar", "dollaren", "dollars"],
            Choices(
                options: [
                    Candidate(reading: .unit(currency("USD")), label: "USD"),
                    Candidate(reading: .unit(currency("CAD")), label: "CAD"),
                    Candidate(reading: .unit(currency("AUD")), label: "AUD"),
                ],
                offer: false
            )
        )
        add(["US$", "usd$"], currency("USD"))
        add(["€", "euro", "euros", "euroen"], currency("EUR"))
        add(["£", "pound sterling", "pounds sterling", "quid"], currency("GBP"))
        add(["¥", "yen"], currency("JPY"))
        add(["yuan", "rmb"], currency("CNY"))
        add(["rupee", "rupees", "₹"], currency("INR"))
        add(["franc", "francs", "franc"], currency("CHF"))
        add(["kroner", "krone", "norske kroner", "nkr", ",-"], currency("NOK"))
        add(["svenske kroner"], currency("SEK"))
        add(["danske kroner"], currency("DKK"))
        add(
            ["kr", "kr."],
            Choices(
                options: [
                    Candidate(reading: .unit(currency("NOK")), label: "NOK"),
                    Candidate(reading: .unit(currency("SEK")), label: "SEK"),
                    Candidate(reading: .unit(currency("DKK")), label: "DKK"),
                ],
                offer: false
            )
        )
        add(["øre"], currency("NOK", factor: Num(1, 100), symbol: "øre"))
        add(["cent", "cents", "¢"], currency("USD", factor: Num(1, 100), symbol: "¢"))
        add(["bitcoin", "bitcoins", "₿"], currency("BTC"))
        add(["sat", "sats", "satoshi", "satoshis"], currency("BTC", factor: r("1e-8"), symbol: "sat"))
        add(["ether", "ethereum"], currency("ETH"))

        // Norwegian words that clash with English.
        norwegian["mil"] = Choices(
            options: [
                Candidate(reading: .unit(norskMil), label: "norsk mil (10 km)"),
                Candidate(reading: .unit(mile), label: "engelsk mil (miles)"),
            ],
            offer: true
        )
        norwegian["time"] = one(hour)
        norwegian["t"] = one(hour)
        norwegian["pund"] = fallback([pound, currency("GBP", label: "pund sterling")])
        norwegian["ss"] = one(ss)
        norwegian["ts"] = one(ts)
        norwegian["spiseskje"] = one(ss)
        norwegian["spiseskjeer"] = one(ss)
        norwegian["teskje"] = one(ts)
        norwegian["teskjeer"] = one(ts)
        norwegian["grader"] = one(celsius)
        norwegian["kopp"] = one(cupMetric)
        norwegian["kopper"] = one(cupMetric)
        exact["mil"] = Choices(
            options: [
                Candidate(reading: .unit(thou), label: "mil = thousandth of an inch"),
                Candidate(reading: .unit(norskMil), label: "norsk mil = 10 km"),
            ],
            offer: true
        )
        exact["miles"] = one(mile)
    }

    /// Units for a word, or nil. Norwegian words win in Norwegian.
    static func lookup(_ w: String, norwegian nb: Bool) -> Choices? {
        ensureBuilt()
        if nb, let c = norwegian[w] ?? norwegian[w.lowercased()] { return c }
        if let c = exact[w] { return c }
        if let c = folded[w.lowercased()] { return c }
        return nil
    }

    static func symbol(_ s: String) -> UnitDef? {
        ensureBuilt()
        return bySymbol[s]
    }
}
