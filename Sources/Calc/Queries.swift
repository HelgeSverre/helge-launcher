import Foundation

/// Whole-query forms that read better as patterns than as grammar: "days until christmas",
/// "time in Tokyo", "week number", "ff in decimal".
enum Queries {
    struct Answer {
        var value: Value
        var alternatives: [(Value, String)] = []
    }

    private static func re(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }

    private static func match(_ r: NSRegularExpression, _ s: String) -> [String]? {
        guard let m = r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let range = m.range(at: i)
            return range.location == NSNotFound ? "" : (s as NSString).substring(with: range)
        }
    }

    private static let spanUnits =
        #"(days?|weeks?|months?|hours?|minutes?|mins?|seconds?|secs?|workdays?|work days|business days|weekdays|dager|dag|uker|timer|minutter|sekunder|virkedager|arbeidsdager|måneder)"#
    private static let until = re(
        "^(?:how many )?" + spanUnits + #" (?:left )?(?:until|till|to|before|igjen til) (.+)$"#
    )
    private static let since = re("^(?:how many )?" + spanUnits + #" (?:since|siden|from) (.+)$"#)
    private static let between = re(
        #"^(?:days|dager|weeks|uker) (?:between|from|mellom|fra) (.+?) (?:and|to|until|og|til) (.+)$"#
    )
    private static let timeIn = re(
        #"^(?:time|current time|clock|klokka|klokken|tiden|tid|what time is it|hva er klokka) (?:in|i) (.+)$"#
    )
    private static let timeDiff = re(
        #"^(?:time ?diff(?:erence)?|tidsforskjell|tidsforskjellen)(?: between| mellom)? (.+?)(?: and | og | to | )(.+)$"#
    )
    private static let weekNow = re(#"^(?:week|week number|current week|this week|uke|ukenummer|uke nr|hvilken uke)$"#)
    private static let weekOf = re(#"^(?:week|uke) (\d{1,2})(?: (\d{4}))?$"#)
    private static let weekday = re(
        #"^(?:weekday|day of (?:the )?week|what day is|what day was|ukedag|hvilken dag er) (?:of |for |is |was )?(.+)$"#
    )
    private static let unixFrom = re(#"^(?:unix|epoch|unix time|timestamp) (-?\d{1,12})$"#)
    private static let nowUnix = re(
        #"^(?:now|nå|current time) (?:in|as|to) (?:unix|epoch)(?: time| timestamp)?$|^unix (?:time|timestamp|now)$"#
    )
    private static let age = re(#"^(?:age|alder)(?: (?:born|of|if born|født))? (.+)$"#)
    private static let easter = re(#"^(?:easter|easter sunday|påske|påskedag|første påskedag) (\d{4})$"#)
    private static let baseIn = re(#"^([0-9a-z]+) (?:in )?base (\d{1,2}) (?:in|to) (?:decimal|dec|desimal)$"#)
    private static let hexIn = re(#"^([0-9a-f]+) (?:in|to) (?:decimal|dec|desimal)$"#)

    static func answer(_ s: String, _ ev: Evaluator) throws -> Answer? {
        let nb = ev.nb
        if let m = match(hexIn, s), m[1].contains(where: { $0.isLetter }),
            let v = BigInt(digits: Substring(m[1]), radix: 16)
        {
            return Answer(value: .q(Quantity(.exact(Rational(v)))))
        }
        if let m = match(baseIn, s), let b = Int(m[2]), (2...36).contains(b) {
            guard let v = BigInt(digits: Substring(m[1].lowercased()), radix: b) else {
                throw EvalError.show(nb ? "Ugyldig tall i base \(b)" : "Not a base-\(b) number")
            }
            return Answer(value: .q(Quantity(.exact(Rational(v)))))
        }
        if let m = match(until, s) { return try span(m[1], m[2], ev, forward: true) }
        if let m = match(since, s) { return try span(m[1], m[2], ev, forward: false) }
        if let m = match(between, s) {
            guard let a = try day(m[1], ev, forward: true).first, let b = try day(m[2], ev, forward: true).first else {
                return nil
            }
            let days = ev.calendar.dateComponents([.day], from: a.0, to: b.0).day!
            var q = Quantity(Num(days), [UnitPow(unit: Units.day, power: 1)])
            if m[0].lowercased().hasPrefix("week") || m[0].lowercased().hasPrefix("uke") {
                q = Quantity(Num(days, 7), [UnitPow(unit: Units.week, power: 1)])
            }
            return Answer(value: .q(q))
        }
        if let m = match(timeIn, s), let z = Zones.lookup(m[1].trimmingCharacters(in: .whitespaces)) {
            let first = Answer(
                value: .instant(ev.ctx.now, z.zones[0].zone),
                alternatives: z.zones.dropFirst().map { (.instant(ev.ctx.now, $0.zone), $0.label) }
            )
            return first
        }
        if let m = match(timeDiff, s), let a = Zones.lookup(m[1]), let b = Zones.lookup(m[2]) {
            let d = b.zones[0].zone.secondsFromGMT(for: ev.ctx.now) - a.zones[0].zone.secondsFromGMT(for: ev.ctx.now)
            var q = Quantity(Num(d), [UnitPow(unit: Units.second, power: 1)])
            q.hint = .duration
            return Answer(value: .q(q))
        }
        if match(weekNow, s) != nil {
            return Answer(value: .q(Quantity(Num(ev.calendar.component(.weekOfYear, from: ev.ctx.now)))))
        }
        if let m = match(weekOf, s), let w = Int(m[1]) {
            let year = Int(m[2]) ?? ev.calendar.component(.yearForWeekOfYear, from: ev.ctx.now)
            var c = DateComponents()
            c.weekOfYear = w
            c.yearForWeekOfYear = year
            c.weekday = 2
            guard (1...53).contains(w), let d = ev.calendar.date(from: c) else { return nil }
            let dc = ev.calendar.dateComponents([.year, .month, .day], from: d)
            return Answer(value: .date(y: dc.year!, m: dc.month!, d: dc.day!))
        }
        if let m = match(weekday, s), let d = try day(m[1], ev, forward: true).first {
            let f = DateFormatter()
            f.locale = Locale(identifier: nb ? "nb_NO" : "en_US")
            f.timeZone = ev.ctx.timeZone
            f.dateFormat = "EEEE"
            return Answer(value: .text(f.string(from: d.0)))
        }
        if let m = match(unixFrom, s), let n = Double(m[1]) {
            return Answer(value: .instant(Date(timeIntervalSince1970: n), TimeZone(secondsFromGMT: 0)!))
        }
        if match(nowUnix, s) != nil {
            var q = Quantity(Num(Int(ev.ctx.now.timeIntervalSince1970)))
            q.hint = .scale("raw")
            return Answer(value: .q(q))
        }
        if let m = match(age, s), let d = try day(m[1], ev, forward: false).first {
            let years = ev.calendar.dateComponents([.year], from: d.0, to: ev.ctx.now).year!
            return Answer(value: .q(Quantity(Num(years), [UnitPow(unit: Units.year, power: 1)])))
        }
        if let m = match(easter, s), let y = Int(m[1]) {
            let (mo, d) = easterSunday(y)
            return Answer(value: .date(y: y, m: mo, d: d))
        }
        return nil
    }

    /// "days until christmas", "minutes until midnight", "workdays until 24 dec".
    static func span(_ unitWord: String, _ target: String, _ ev: Evaluator, forward: Bool) throws -> Answer? {
        let u = unitWord.lowercased()
        let days = try day(target, ev, forward: forward)
        guard !days.isEmpty else { return nil }
        let now = ev.ctx.now
        let startOfToday = ev.calendar.startOfDay(for: now)
        func value(_ d: Date) -> Value {
            if u.hasPrefix("work") || u.hasPrefix("business") || u.hasPrefix("weekday") || u.hasPrefix("virke")
                || u.hasPrefix("arbeids")
            {
                var n = 0
                var cur = forward ? startOfToday : d
                let end = forward ? d : startOfToday
                while cur < end {
                    let wd = ev.calendar.component(.weekday, from: cur)
                    if wd != 1 && wd != 7 { n += 1 }
                    cur = ev.calendar.date(byAdding: .day, value: 1, to: cur)!
                }
                return .q(Quantity(Num(n), [UnitPow(unit: Units.workday, power: 1)]))
            }
            if u.hasPrefix("day") || u.hasPrefix("dag") {
                let n = ev.calendar.dateComponents(
                    [.day],
                    from: forward ? startOfToday : d,
                    to: forward ? d : startOfToday
                ).day!
                return .q(Quantity(Num(n), [UnitPow(unit: Units.day, power: 1)]))
            }
            if u.hasPrefix("week") || u.hasPrefix("uke") {
                let n = ev.calendar.dateComponents(
                    [.day],
                    from: forward ? startOfToday : d,
                    to: forward ? d : startOfToday
                ).day!
                return .q(Quantity(Num(n, 7), [UnitPow(unit: Units.week, power: 1)]))
            }
            if u.hasPrefix("month") || u.hasPrefix("måned") {
                let n = ev.calendar.dateComponents(
                    [.month],
                    from: forward ? startOfToday : d,
                    to: forward ? d : startOfToday
                ).month!
                return .q(Quantity(Num(n), [UnitPow(unit: Units.month, power: 1)]))
            }
            let secs = Int((forward ? d.timeIntervalSince(now) : now.timeIntervalSince(d)).rounded())
            let unit: UnitDef =
                u.hasPrefix("hour") || u.hasPrefix("time")
                ? Units.hour : (u.hasPrefix("min") ? Units.minute : Units.second)
            let q = Quantity(Num(secs, Int(unit.factor.double)), [UnitPow(unit: unit, power: 1)])
            return .q(q)
        }
        return Answer(value: value(days[0].0), alternatives: days.dropFirst().map { (value($0.0), $0.1) })
    }

    /// A day named in words or digits; holidays may have several readings.
    static func day(_ text: String, _ ev: Evaluator, forward: Bool) throws -> [(Date, String)] {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        let nb = ev.nb
        let now = ev.ctx.now
        let cal = ev.calendar
        let year = cal.component(.year, from: now)
        func occurrence(_ m: Int, _ d: Int) -> Date {
            var y = year
            var date = cal.date(from: DateComponents(year: y, month: m, day: d))!
            let today = cal.startOfDay(for: now)
            if forward && date < today { y += 1 } else if !forward && date > today { y -= 1 }
            date = cal.date(from: DateComponents(year: y, month: m, day: d))!
            return date
        }
        switch t {
        case "midnight", "midnatt":
            let next = cal.date(byAdding: .day, value: forward ? 1 : 0, to: cal.startOfDay(for: now))!
            return [(next, "")]
        case "noon", "midday":
            return [(cal.date(bySettingHour: 12, minute: 0, second: 0, of: now)!, "")]
        case "christmas", "xmas", "christmas day":
            return [(occurrence(12, 25), "")]
        case "christmas eve", "julaften":
            return [(occurrence(12, 24), "")]
        case "jul", "julen":
            return [(occurrence(12, 24), "julaften 24. desember"), (occurrence(12, 25), "første juledag 25. desember")]
        case "new year", "new years", "new year's", "new year's day", "nyttår", "nyttårsdag", "1. januar":
            return [(occurrence(1, 1), "")]
        case "new year's eve", "nyttårsaften":
            return [(occurrence(12, 31), "")]
        case "halloween": return [(occurrence(10, 31), "")]
        case "valentine's", "valentines", "valentine's day", "valentinsdagen": return [(occurrence(2, 14), "")]
        case "midsummer", "sankthans", "sankthansaften", "st. hans": return [(occurrence(6, 23), "")]
        case "17. mai", "grunnlovsdagen", "nasjonaldagen", "syttende mai": return [(occurrence(5, 17), "")]
        case "easter", "påske", "påskedag":
            var y = year
            var (m, d) = easterSunday(y)
            var date = cal.date(from: DateComponents(year: y, month: m, day: d))!
            if forward && date < cal.startOfDay(for: now) {
                y += 1
                (m, d) = easterSunday(y)
                date = cal.date(from: DateComponents(year: y, month: m, day: d))!
            }
            return [(date, "")]
        case "today", "i dag", "idag": return [(cal.startOfDay(for: now), "")]
        case "tomorrow", "i morgen", "imorgen":
            return [(cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!, "")]
        default:
            break
        }
        // Anything the grammar reads as a date: "25 dec", "2026-12-31", "17. mai".
        let toks = try Lexer.tokenize(Lexer.normalize(text), locale: ev.ctx.locale)
        guard toks.count == 1 else { return [] }
        var lits: [DateLit] = []
        switch toks[0].tok {
        case .date(let d): lits = [d]
        case .choice(let alts, _):
            for a in alts { if case .date(let d) = a.toks[0].tok { lits.append(d) } }
        default: return []
        }
        _ = nb
        return try lits.map { d in
            if let y = d.year {
                return (try ev.makeDate(y, d.month, d.day, 0, 0, 0, ev.ctx.timeZone), "")
            }
            _ = try ev.makeDate(year, d.month, d.day, 0, 0, 0, ev.ctx.timeZone)
            return (occurrence(d.month, d.day), "")
        }
    }

    /// Anonymous Gregorian algorithm.
    static func easterSunday(_ y: Int) -> (Int, Int) {
        let a = y % 19
        let b = y / 100
        let c = y % 100
        let d = b / 4
        let e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4
        let k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = ((h + l - 7 * m + 114) % 31) + 1
        return (month, day)
    }
}

extension Units {
    static let workday = UnitDef(
        id: "workday",
        symbol: "workdays",
        dim: .none,
        factor: .one,
        words: ("workday", "workdays"),
        wordsNb: ("virkedag", "virkedager")
    )
}
