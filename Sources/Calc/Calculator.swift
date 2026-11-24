import Foundation

/// Number formatting and language for queries and answers.
public struct CalcLocale: Sendable {
    /// Norwegian answers and messages.
    public var nb: Bool
    /// Norwegian words in queries ("i", "av", "mil" = 10 km); on for Norwegian speakers and regions.
    public var acceptsNorwegian: Bool
    public var decimalMark: Character
    public var groupSeparator: Character
    public var groupFourDigits: Bool
    public var dayFirst: Bool

    public static let en = CalcLocale(
        nb: false,
        decimalMark: ".",
        groupSeparator: ",",
        groupFourDigits: true,
        dayFirst: false
    )
    public static let nb = CalcLocale(
        nb: true,
        decimalMark: ",",
        groupSeparator: "\u{00A0}",
        groupFourDigits: false,
        dayFirst: true
    )

    public init(
        nb: Bool,
        acceptsNorwegian: Bool? = nil,
        decimalMark: Character,
        groupSeparator: Character,
        groupFourDigits: Bool,
        dayFirst: Bool
    ) {
        self.nb = nb
        self.acceptsNorwegian = acceptsNorwegian ?? nb
        self.decimalMark = decimalMark
        self.groupSeparator = groupSeparator
        self.groupFourDigits = groupFourDigits
        self.dayFirst = dayFirst
    }

    /// `nb_NO`, `nn_NO`, `no` → Norwegian; everything else English (day-first outside the US).
    public init(identifier: String) {
        let id = identifier.lowercased()
        if id.hasPrefix("nb") || id.hasPrefix("nn") || id.hasPrefix("no") {
            self = .nb
        } else {
            self = .en
            dayFirst = !(id.hasSuffix("us") || id == "en")
        }
    }

    /// From the system: number format of the region, Norwegian words for Norwegian speakers or regions.
    public static func system(
        _ locale: Locale = .current,
        languages: [String] = Locale.preferredLanguages
    ) -> CalcLocale {
        let lang = locale.language.languageCode?.identifier ?? "en"
        let region = locale.region?.identifier ?? ""
        let norwegian = ["nb", "nn", "no"]
        var c: CalcLocale = norwegian.contains(lang) ? .nb : .en
        // Queries read "." as the decimal point and "," as grouping whatever the region says;
        // answers always print 1 000 000.00.
        c.decimalMark = "."
        c.groupSeparator = ","
        c.dayFirst = region != "US"
        c.acceptsNorwegian =
            c.nb || region == "NO" || languages.contains { l in norwegian.contains { l.hasPrefix($0) } }
        return c
    }
}

/// Exchange rates as NOK per unit of each currency.
public struct RateTable: Sendable {
    var nokPer: [String: Num]
    /// ISO date of the rates.
    public var date: String

    public init(nokPer: [String: String], date: String) {
        self.nokPer = nokPer.compactMapValues { Num(decimal: $0) }
        self.date = date
    }

    public init(nokPer: [String: Double], date: String) {
        self.nokPer = nokPer.mapValues { Num(decimal: String(format: "%.12g", $0)) ?? .approx($0) }
        self.date = date
    }
}

public struct CalcContext {
    public var locale: CalcLocale
    public var now: Date
    public var timeZone: TimeZone
    public var rates: RateTable?
    public var previousAnswer: CalcAnswer?
    var variables: [String: Value] = [:]

    public init(
        locale: CalcLocale = .en,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        rates: RateTable? = nil,
        previousAnswer: CalcAnswer? = nil
    ) {
        self.locale = locale
        self.now = now
        self.timeZone = timeZone
        self.rates = rates
        self.previousAnswer = previousAnswer
    }
}

/// One reading of a query.
public struct CalcAnswer {
    let value: Value
    let targeted: Bool
    /// What makes this reading different ("US gallon"); nil for the only reading.
    public let label: String?
    /// Locale-free text: `.` decimal, no grouping, 10 significant digits.
    public let canonical: String
    public let canonicalUnit: String?
    /// For people, in the query's locale.
    public let display: String
    public let displayUnit: String?
    /// Kind of value, for the UI.
    public let kind: Kind
    /// Secondary text beside the answer: the date and place of a time ("Tuesday 24 November · Oslo").
    public var detail: String? = nil
    /// The number alone with a `.` decimal point and no grouping, for spreadsheets; other values as shown.
    public var plain: String {
        switch kind {
        case .number, .quantity, .money:
            guard Double(canonical) != nil || canonical.contains("e") else { return display }
            return canonical
        default:
            return display
        }
    }

    public enum Kind: Sendable {
        case number, quantity, money, date, time, text, bool
    }

    /// Display text with unit.
    public var text: String {
        guard let u = displayUnit, !u.isEmpty else { return display }
        if u == "%" { return display + " %" }
        if u.hasPrefix("/") { return display + u }
        return display + " " + u
    }

    /// Canonical text with unit: what "Copy raw" copies.
    public var raw: String {
        guard let u = canonicalUnit, !u.isEmpty else { return canonical }
        return u.hasPrefix("/") ? canonical + u : canonical + " " + u
    }
}

public struct CalcResult {
    public let primary: CalcAnswer
    public let alternatives: [CalcAnswer]
    /// The query as understood, e.g. "1.5 L/day × 365 days × 2 NOK/mL → USD".
    public let interpretation: String
    /// The interpretation says more than the query itself; otherwise the UI leaves it out.
    public var showsInterpretation: Bool { CalcResult.essence(interpretation) != CalcResult.essence(query) }
    /// What was typed.
    public var query: String = ""
    /// Intermediate results of a chain ("500 km", "@ 6 L ÷ 100 km  30 L", …); empty for one-step queries.
    public var steps: [CalcStep] = []

    static func essence(_ s: String) -> String {
        var t = s.lowercased()
        for (a, b) in [("×", "*"), ("÷", "/"), ("−", "-"), ("→", "in"), ("@", "at"), (",", "."), ("\u{00A0}", "")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t.filter { !$0.isWhitespace && $0 != "(" && $0 != ")" }
    }

    /// Exchange rates were used.
    public let usedRates: Bool
    public let rateDate: String?
}

public enum CalcOutcome {
    /// Not a calculation.
    case none
    /// A calculation that has no answer, with the reason.
    case error(String)
    case result(CalcResult)

    public var result: CalcResult? {
        if case .result(let r) = self { return r }
        return nil
    }
}

public enum Calculator {
    /// Phone numbers and similar digit runs are never calculations.
    private static let phoneLike = try! NSRegularExpression(
        pattern: #"^(\+\d[\d ]{5,}|\d{3,4}-\d{3,4}(-\d{2,4})?|\d{2,3}( \d{2}){3,})$"#
    )

    public static func evaluate(_ input: String, _ ctx: CalcContext = CalcContext()) -> CalcOutcome {
        Units.ensureBuilt()
        let normalized = Lexer.normalize(input)
        if normalized.isEmpty || normalized.count > 2000 { return .none }
        if phoneLike.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) != nil {
            return .none
        }
        let (rewritten, extraQueries) = Rewriter.rewrite(normalized, locale: ctx.locale)

        // Whole-query patterns (dates, base conversions).
        let ev = Evaluator(ctx)
        do {
            if let a = try Queries.answer(rewritten, ev) {
                let out = Output(ev: ev)
                let primary = answer(a.value, label: a.alternatives.isEmpty ? nil : nil, targeted: true, out)
                let alts = a.alternatives.map { answer($0.0, label: $0.1, targeted: true, out) }
                var labelled = primary
                if !alts.isEmpty,
                    let first = try? Queries.day(String(rewritten.split(separator: " ").last ?? ""), ev, forward: true)
                        .first?.1, !first.isEmpty
                {
                    labelled = answer(a.value, label: first, targeted: true, out)
                }
                return .result(
                    withQuery(
                        input,
                        CalcResult(
                            primary: labelled,
                            alternatives: alts,
                            interpretation: normalized,
                            usedRates: false,
                            rateDate: nil
                        )
                    )
                )
            }
        } catch let e as EvalError {
            if let m = e.message { return .error(m) }
            return .none
        } catch {}

        let tokens: [Token]
        do {
            tokens = try Lexer.tokenize(rewritten, locale: ctx.locale)
        } catch let f as LexFailure {
            return f.message.map { .error($0) } ?? .none
        } catch {
            return .none
        }
        if tokens.isEmpty { return .none }

        let readings = expand(tokens)
        var firstError: String?
        for reading in readings {
            var parser = Parser(reading.tokens)
            guard let node = try? parser.parseProgram() else { continue }
            let ev = Evaluator(ctx)
            do {
                let v = try ev.eval(node)
                if node.isTrivial { return .none }
                let out = Output(ev: ev)
                let targeted = isTargeted(node)
                let primary = answer(v, label: nil, targeted: targeted, out)
                var alts: [CalcAnswer] = []
                func addAlt(_ a: CalcAnswer) {
                    if a.raw == primary.raw || alts.contains(where: { $0.raw == a.raw }) { return }
                    alts.append(a)
                }
                // Other readings of words that have several meanings.
                for alt in deviations(tokens, from: reading) {
                    var p = Parser(alt.tokens)
                    guard let n = try? p.parseProgram() else { continue }
                    let e2 = Evaluator(ctx)
                    if let v2 = try? e2.eval(n) {
                        addAlt(answer(v2, label: alt.label, targeted: isTargeted(n), Output(ev: e2)))
                    }
                }
                // Implicit multiplication binding tighter.
                var tp = Parser(reading.tokens, tight: true)
                if let n = try? tp.parseProgram(), let v2 = try? Evaluator(ctx).eval(n) {
                    let a = answer(
                        v2,
                        label: Describe.node(n, ctx.locale),
                        targeted: isTargeted(n),
                        Output(ev: Evaluator(ctx))
                    )
                    if a.raw != primary.raw { addAlt(a) }
                }
                for (xv, label) in ev.extras { addAlt(answer(xv, label: label, targeted: true, out)) }
                for x in extraQueries {
                    if case .result(let r) = evaluate(x.query, ctx) {
                        addAlt(
                            CalcAnswer(
                                value: r.primary.value,
                                targeted: r.primary.targeted,
                                label: x.label,
                                canonical: r.primary.canonical,
                                canonicalUnit: r.primary.canonicalUnit,
                                display: r.primary.display,
                                displayUnit: r.primary.displayUnit,
                                kind: r.primary.kind
                            )
                        )
                    }
                }
                // Fractions for exact non-terminating results.
                if case .q(let q) = v, q.isPlain, let r = q.value.rational, !r.isInteger, let d = r.den.int, d <= 1000,
                    !terminates(d)
                {
                    addAlt(
                        CalcAnswer(
                            value: .text("\(r.num)/\(r.den)"),
                            targeted: true,
                            label: ctx.locale.nb ? "brøk" : "fraction",
                            canonical: "\(r.num)/\(r.den)",
                            canonicalUnit: nil,
                            display: "\(r.num)/\(r.den)",
                            displayUnit: nil,
                            kind: .number
                        )
                    )
                }
                var labelledPrimary = primary
                if !alts.isEmpty, let l = primaryLabel(tokens, reading) ?? reading.labels.compactMap({ $0 }).first {
                    labelledPrimary = answer(v, label: l, targeted: targeted, out)
                }
                return .result(
                    withQuery(
                        input,
                        CalcResult(
                            primary: labelledPrimary,
                            alternatives: alts,
                            interpretation: Describe.node(node, ctx.locale),
                            usedRates: ev.usedRates,
                            rateDate: ev.usedRates ? ctx.rates?.date : nil
                        ),
                        steps: Steps.of(node, ctx)
                    )
                )
            } catch let e as EvalError {
                if firstError == nil, let m = e.message { firstError = m }
            } catch {}
        }
        return firstError.map { .error($0) } ?? .none
    }

    private static func withQuery(_ q: String, _ r: CalcResult, steps: [CalcStep] = []) -> CalcResult {
        var r = r
        r.query = q
        r.steps = steps
        return r
    }

    private static func terminates(_ d: Int) -> Bool {
        var d = d
        while d % 2 == 0 { d /= 2 }
        while d % 5 == 0 { d /= 5 }
        return d == 1
    }

    static func isTargeted(_ n: Node) -> Bool {
        switch n {
        case .convert: return true
        case .seq(let ns): return ns.last.map(isTargeted) ?? false
        case .assign(_, let e): return isTargeted(e)
        default: return false
        }
    }

    static func answer(_ v: Value, label: String?, targeted: Bool, _ out: Output) -> CalcAnswer {
        let c = out.canonical(v, targeted: targeted)
        var d = out.display(v, targeted: targeted)
        let kind: CalcAnswer.Kind
        switch v {
        case .q(let q):
            let money = q.units.contains { $0.unit.currency != nil } && q.units.count == 1
            kind = money ? .money : (q.units.isEmpty ? .number : .quantity)
            if money, q.hint == .none, case .q(let shaped) = Value.q(targeted ? q : out.normalize(q)) {
                // Money: two decimals; crypto, rates and tiny amounts keep more.
                let code = shaped.units.first?.unit.currency ?? ""
                let a = shaped.value.abs
                let places = ["BTC", "ETH"].contains(code) ? 8 : (a < Num(1) && !a.isZero ? 4 : 2)
                let rounded = shaped.value.rounded(.toNearestOrAwayFromZero, places: places)
                d.value = Format.display(rounded, locale: out.ev.ctx.locale, maxFraction: places)
                if places == 2, !(rounded.rational?.isInteger ?? false) {
                    let mark: Character = "."
                    let parts = d.value.split(separator: mark)
                    if parts.count == 1 {
                        d.value += String(mark) + "00"
                    } else if parts[1].count == 1 {
                        d.value += "0"
                    }
                }
            }
            if case .scale("raw") = q.hint { d.value = c.value }
        case .date: kind = .date
        case .instant, .clock: kind = .time
        case .text: kind = .text
        case .bool: kind = .bool
        }
        var detail: String?
        if case .instant(let date, let tz) = v {
            (d.value, detail) = Describe.instantParts(date, tz, nb: out.nb, now: out.ev.ctx.now)
        }
        if case .date(let y, let m, let dd) = v { d.value = Describe.date(y, m, dd, nb: out.nb) }
        return CalcAnswer(
            value: v,
            targeted: targeted,
            label: label,
            canonical: c.value,
            canonicalUnit: c.unit,
            display: d.value,
            displayUnit: d.unit,
            kind: kind,
            detail: detail
        )
    }

    // MARK: Readings

    struct Reading {
        var tokens: [Token]
        var labels: [String?]
        var picks: [Int]
    }

    /// Choice positions in order.
    private static func choicePoints(_ toks: [Token]) -> [(Int, [Alt], Bool)] {
        toks.enumerated().compactMap { i, t in
            if case .choice(let alts, let offer) = t.tok { return (i, alts, offer) }
            return nil
        }
    }

    private static func build(_ toks: [Token], _ picks: [Int]) -> Reading {
        var out: [Token] = []
        var labels: [String?] = []
        var k = 0
        for t in toks {
            if case .choice(let alts, _) = t.tok {
                let a = alts[picks[k]]
                out += a.toks
                labels.append(a.label)
                k += 1
            } else {
                out.append(t)
            }
        }
        return Reading(tokens: out, labels: labels, picks: picks)
    }

    /// Readings in order of preference: fewest non-first picks first.
    static func expand(_ toks: [Token]) -> [Reading] {
        let points = choicePoints(toks)
        if points.isEmpty { return [Reading(tokens: toks, labels: [], picks: [])] }
        var all: [[Int]] = [[]]
        for p in points {
            all = all.flatMap { prefix in (0..<p.1.count).map { prefix + [$0] } }
            if all.count > 512 { break }
        }
        all = all.filter { $0.count == points.count }
        all.sort { a, b in
            let da = a.filter { $0 != 0 }.count
            let db = b.filter { $0 != 0 }.count
            if da != db { return da < db }
            return a.lexicographicallyPrecedes(b)
        }
        return all.prefix(256).map { build(toks, $0) }
    }

    /// Measuring system named in a reading's label, so "3/4 cup in tbsp" switches both words together.
    private static func system(_ label: String?) -> String? {
        guard let l = label?.lowercased() else { return nil }
        if l.contains("imperial") || l.contains("(imp") { return "imp" }
        if l.contains("metric") { return "metric" }
        if l.contains("australian") { return "au" }
        if l.contains("us ") || l.hasPrefix("us") { return "us" }
        return nil
    }

    /// The label of the primary reading's first offered choice.
    private static func primaryLabel(_ toks: [Token], _ reading: Reading) -> String? {
        for (k, p) in choicePoints(toks).enumerated() where p.2 {
            if let l = p.1[reading.picks[k]].label { return l }
        }
        return nil
    }

    /// One offered choice changed from `reading`; other words of the same measuring system follow it.
    private static func deviations(_ toks: [Token], from reading: Reading) -> [(tokens: [Token], label: String?)] {
        let points = choicePoints(toks)
        var out: [([Token], String?)] = []
        var seen = Set<[Int]>()
        // Only the first word with several readings varies; the rest follow its measuring system.
        for (k, p) in points.enumerated() where p.2 && k == points.firstIndex(where: { $0.2 }) {
            for j in 0..<p.1.count where j != reading.picks[k] {
                var picks = reading.picks
                picks[k] = j
                if let sys = system(p.1[j].label) {
                    for (k2, p2) in points.enumerated() where k2 != k && p2.2 {
                        if let j2 = p2.1.firstIndex(where: { system($0.label) == sys }) { picks[k2] = j2 }
                    }
                }
                guard seen.insert(picks).inserted else { continue }
                out.append((build(toks, picks).tokens, p.1[j].label))
            }
        }
        return out
    }
}
