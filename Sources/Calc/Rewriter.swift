import Foundation

/// Natural-language phrasing to the symbolic grammar, as ordered regex rewrites.
/// Each rule's replacement uses `$1`… for captures.
enum Rewriter {
    struct Rule {
        let re: NSRegularExpression
        let template: String

        init(_ pattern: String, _ template: String) {
            re = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            self.template = template
        }
    }

    /// Phrases that also produce an alternative reading, e.g. tip totals.
    struct Extra {
        var query: String
        var label: String
    }

    private static let common: [Rule] = [
        Rule(#"^(?:what is|what's|whats|how much is|calculate|calc|compute|solve|hva er|hvor mye er|regn ut)\s+"#, ""),
        Rule(#"\s+is what$"#, ""),
        Rule(#"\s+er hva$"#, ""),
        // Percent questions
        Rule(#"^(.+?) is what ?(?:%|percent|percentage) of (.+)$"#, "($1) / ($2) as %"),
        Rule(#"^(.+?) er hvor mange prosent av (.+)$"#, "($1) / ($2) as %"),
        Rule(#"^(.+?) is (.+?) ?% of what$"#, "($1) / ($2 %)"),
        Rule(#"^(.+?) is (.+?) ?% on what$"#, "($1) / (1 + $2 %)"),
        Rule(#"^(.+?) is (.+?) ?% off what$"#, "($1) / (1 - $2 %)"),
        Rule(#"^(.+?) to (.+?) is what ?(?:%|percent)$"#, "(($2) - ($1)) / ($1) as %"),
        Rule(#"^(.+?) ?% (?:off|discount on|discount off|rabatt på|avslag på) (.+)$"#, "($2) - $1 %"),
        Rule(#"^(.+?) ?% (?:decrease|reduction|less|lower) (?:from|of|on) (.+)$"#, "($2) - $1 %"),
        Rule(#"^(.+?) ?% (?:increase|more|higher) (?:from|of|on) (.+)$"#, "($2) + $1 %"),
        Rule(#"^(?:a |an )?(.+?) ?% tip (?:on|for) (?:a |an |the )?(.+?)(?: bill| check)?$"#, "$1 % of ($2)"),
        Rule(#"^(.+?) ?% (?:on|påslag på) (.+)$"#, "($2) + $1 %"),
        // VAT
        Rule(#"(\d) ?% (?:vat|tax|mva|moms|gst)\b"#, "$1 %"),
        Rule(#"\+ ?(?:mva|vat|moms)\b"#, "+ 25 %"),
        Rule(#"\b(?:uten|eks|ekskl|ekskludert|ex|excl|excluding|minus) ?(?:mva|vat|moms)\b"#, "/ 1.25"),
        Rule(#"\b(?:med|inkl|inkludert|incl|including|with) ?(?:mva|vat|moms)\b"#, "* 1.25"),
        // Ordering words
        Rule(#"^remainder of (.+?) divided by (.+)$"#, "$1 mod $2"),
        Rule(#"^resten av (.+?) delt på (.+)$"#, "$1 mod $2"),
        Rule(#"^subtract (.+?) from (.+)$"#, "($2) - ($1)"),
        Rule(#"^trekk (.+?) fra (.+)$"#, "($2) - ($1)"),
        Rule(#"^add (.+?) to (.+)$"#, "($2) + ($1)"),
        Rule(#"^split (.+?) (?:between|among|by|into|on|mellom|på) (.+)$"#, "($1) / ($2)"),
        Rule(#"^del (.+?) (?:mellom|på) (.+)$"#, "($1) / ($2)"),
        Rule(#"^(.+?) less than (.+)$"#, "($2) - ($1)"),
        Rule(#"^(.+?) more than (.+)$"#, "($2) + ($1)"),
        Rule(#"^(.+?) mindre enn (.+)$"#, "($2) - ($1)"),
        Rule(#"^(.+?) mer enn (.+)$"#, "($2) + ($1)"),
        // Temperature differences
        Rule(#"^(.+?) degrees? (c|f|celsius|fahrenheit) (?:warmer|hotter|higher|more) than (.+)$"#, "$3 + delta $1 $2"),
        Rule(#"^(.+?) degrees? (c|f|celsius|fahrenheit) (?:colder|cooler|lower|less) than (.+)$"#, "$3 - delta $1 $2"),
        Rule(#"\ba (?:change|difference|rise|drop|increase|decrease) of\b"#, "delta"),
        // How many
        Rule(#"^how many (.+?) (?:are )?(?:there )?(?:in|is in|per) (.+)$"#, "$2 in $1"),
        Rule(#"^hvor mange (.+?) (?:er det )?(?:i|på) (.+)$"#, "$2 in $1"),
        // Functions and operators in words
        Rule(#"\b(?:the )?square root of\b"#, "sqrt"),
        Rule(#"\b(?:the )?cube root of\b"#, "cbrt"),
        Rule(#"\bkvadratrot(?:en)? av\b"#, "sqrt"),
        Rule(#"\broten av\b"#, "sqrt"),
        Rule(#"\bto the power of\b|\braised to(?: the power of)?\b|\bopphøyd i\b"#, "^"),
        Rule(#"\bsquared\b|\bi andre\b"#, "^2"),
        Rule(#"\bcubed\b|\bi tredje\b"#, "^3"),
        Rule(#"\bdivided by\b|\bdelt på\b|\bdelt med\b"#, "/"),
        Rule(#"\bmultiplied by\b|\bganget med\b"#, "*"),
        Rule(#"\bhalf of\b|\bhalvparten av\b|\bhalve\b"#, "1/2 of"),
        Rule(#"\bhalf an?\b|\ben halv\b|\bet halvt\b"#, "1/2"),
        Rule(#"\ba quarter of\b|\bquarter of\b|\ben fjerdedel av\b"#, "1/4 of"),
        Rule(#"\ben kvart\b|\bet kvart\b"#, "1/4"),
        Rule(#"\bet kvarter\b"#, "15 min"),
        Rule(#"\ba third of\b|\ben tredjedel av\b"#, "1/3 of"),
        Rule(#"\btwice\b|\bdouble\b|\bdobbelt\b|\bdobbelte\b"#, "2 *"),
        Rule(#"\btriple\b|\btrippel\b"#, "3 *"),
        Rule(#"\bquadruple\b"#, "4 *"),
        Rule(#"\ba couple of\b|\bet par\b"#, "2"),
        Rule(#"\ba baker'?s dozen\b"#, "13"),
        Rule(#"\bhalvannen\b|\bhalvannet\b|\bhalvanna\b"#, "1.5"),
        Rule(#"\bone and a half\b"#, "1.5"),
        Rule(#"\b(\d+) and a half\b"#, "$1.5"),
        Rule(#"\bto og en halv\b"#, "2.5"),
    ]

    private static let norwegianOnly: [Rule] = [
        Rule(#"\bi dag\b"#, "today"),
        Rule(#"\bi morgen\b"#, "tomorrow"),
        Rule(#"\bi går\b"#, "yesterday"),
        Rule(#"\bkm/t\b"#, "km/h"),
        Rule(#"\bganger\b|\bgange\b"#, "*"),
        Rule(#"\bav\b"#, "of"),
        Rule(#"\bog\b"#, "and"),
        Rule(#"\bi\b"#, "in"),
        Rule(#"\btil\b"#, "to"),
        Rule(#"\bpå\b"#, "at"),
    ]

    /// "sum of 1 2 3 4", "average of 10, 20 and 60".
    private static let listRule = try! NSRegularExpression(
        pattern: #"^(sum|total|average|mean|avg|product|summen|gjennomsnittet|gjennomsnitt|snittet) (?:of |av )?(.+)$"#,
        options: [.caseInsensitive]
    )

    static func rewrite(_ input: String, locale: CalcLocale) -> (String, [Extra]) {
        var s = input
        var extras: [Extra] = []
        if let m = listRule.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) {
            let fn = (s as NSString).substring(with: m.range(at: 1)).lowercased()
            var items = (s as NSString).substring(with: m.range(at: 2))
            for sep in [" and ", " og ", ", ", "; "] { items = items.replacingOccurrences(of: sep, with: " ; ") }
            let parts = items.split(separator: " ").map(String.init)
            // Space-separated numbers become separate items; units stay with their number.
            var args: [String] = []
            var cur = ""
            for p in parts {
                if p == ";" {
                    if !cur.isEmpty { args.append(cur) }
                    cur = ""
                } else if !cur.isEmpty && p.first?.isNumber == true && cur.last?.isNumber == true {
                    args.append(cur)
                    cur = p
                } else {
                    cur += (cur.isEmpty ? "" : " ") + p
                }
            }
            if !cur.isEmpty { args.append(cur) }
            let name = ["sum", "total", "summen"].contains(fn) ? "sum" : (fn == "product" ? "product" : "avg")
            if args.count >= 2 { return ("\(name)(\(args.joined(separator: "; ")))", []) }
        }
        let tip = try! NSRegularExpression(
            pattern: #"^(?:a |an )?(.+?) ?% tip (?:on|for) (?:a |an |the )?(.+?)(?: bill| check)?$"#,
            options: [.caseInsensitive]
        )
        if let m = tip.firstMatch(
            in: stripQuestion(s),
            range: NSRange(stripQuestion(s).startIndex..., in: stripQuestion(s))
        ) {
            let t = stripQuestion(s) as NSString
            extras.append(
                Extra(
                    query: "(\(t.substring(with: m.range(at: 2)))) + \(t.substring(with: m.range(at: 1))) %",
                    label: locale.nb ? "totalt" : "total"
                )
            )
        }
        let root = try! NSRegularExpression(
            pattern: #"^(?:the )?square root of (.+? (?:times|\*|plus|\+|minus|-|divided by|/) .+)$"#,
            options: [.caseInsensitive]
        )
        if let m = root.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) {
            extras.append(Extra(query: "sqrt(\((s as NSString).substring(with: m.range(at: 1))))", label: "√(…)"))
        }
        let gas = try! NSRegularExpression(
            pattern: #"^gas ?mark (\d)(?: (?:in|to) (c|celsius|°c|f|fahrenheit|°f))?$"#,
            options: [.caseInsensitive]
        )
        if let m = gas.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
            let n = Int((s as NSString).substring(with: m.range(at: 1))), (1...9).contains(n)
        {
            let c = [140, 150, 170, 180, 190, 200, 220, 230, 240][n - 1]
            let unit = m.range(at: 2).location == NSNotFound ? "c" : (s as NSString).substring(with: m.range(at: 2))
            s = "\(c) C in \(unit)"
        }
        let rules = common + (locale.acceptsNorwegian ? norwegianOnly : [])
        for r in rules {
            s = r.re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: r.template)
        }
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return (s.trimmingCharacters(in: .whitespaces), extras)
    }

    private static func stripQuestion(_ s: String) -> String {
        let re = try! NSRegularExpression(
            pattern: #"^(?:what is|what's|whats|how much is)\s+"#,
            options: [.caseInsensitive]
        )
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }
}
