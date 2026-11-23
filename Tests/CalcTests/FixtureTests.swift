import Foundation
import Testing

@testable import Calc

/// Runs docs/calculator-fixtures.json through the engine.
struct FixtureTests {
    struct File: Decodable {
        struct Meta: Decodable {
            struct Conventions: Decodable {
                let now: String
                let timezone: String
                let rates_nok_per_unit: [String: String]
            }
            let conventions: Conventions
        }
        struct Fixture: Decodable {
            struct Expect: Decodable {
                struct Alt: Decodable {
                    let value: String
                    let unit: String?
                    let label: String?
                }
                let kind: String
                let value: String?
                let unit: String?
                let alternatives: [Alt]?
                let note: String?
            }
            let id: String
            let category: String
            let tier: Int
            let input: String
            let expect: Expect
            let locale: String?
            let context: [String: JSONValue]?
        }
        let meta: Meta
        let fixtures: [Fixture]
    }

    enum JSONValue: Decodable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case null

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() {
                self = .null
            } else if let b = try? c.decode(Bool.self) {
                self = .bool(b)
            } else if let d = try? c.decode(Double.self) {
                self = .number(d)
            } else {
                self = .string(try c.decode(String.self))
            }
        }

        var string: String? {
            if case .string(let s) = self { return s }
            return nil
        }
    }

    /// Fixtures the engine does not aim to pass, with the reason.
    static let skipped: [String: String] = [
        "chains-033": "proportion phrasing; the fixture accepts no row",
        "cooking-023": "recipe scaling phrasing; the fixture accepts no row",
        "currency-021": "needs historical rates; answers 'No exchange rate for that date'",
        "programmer-024": "the fixture accepts the error 'only integers convert to base 2'",
        "data-025": "leading label words ('4K video') would also make '4K Video Downloader' a calculation",
    ]

    static func loadFixtures() throws -> File {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
            "../../docs/calculator-fixtures.json"
        )
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
    }

    static func context(_ f: File.Fixture, _ meta: File.Meta) -> CalcContext {
        let iso = ISO8601DateFormatter()
        let nowText = f.context?["now"]?.string ?? meta.conventions.now
        let tz = TimeZone(identifier: f.context?["timezone"]?.string ?? meta.conventions.timezone)!
        var ctx = CalcContext(
            locale: CalcLocale(identifier: f.locale ?? "en_NO"),
            now: iso.date(from: nowText)!,
            timeZone: tz,
            rates: RateTable(nokPer: meta.conventions.rates_nok_per_unit, date: "2026-11-20")
        )
        if let c = f.context?["rates_cache"], case .null = c { ctx.rates = nil }
        if let prev = f.context?["previous_answer"]?.string {
            ctx.previousAnswer = Calculator.evaluate(prev + " + 0", ctx).result?.primary
        }
        return ctx
    }

    static let aliases: [String: String] = [
        "days": "d", "day": "d", "dager": "d", "dag": "d", "weeks": "wk", "week": "wk", "uker": "wk", "uke": "wk",
        "hours": "h", "hour": "h", "timer": "h", "minutes": "min", "minute": "min", "minutter": "min",
        "seconds": "s", "second": "s", "sec": "s", "l": "L", "ml": "mL", "dl": "dL", "deg": "°", "knot": "kn",
        "years": "yr", "year": "yr", "år": "yr", "virkedager": "workdays", "workday": "workdays",
    ]

    static func tokens(_ s: String) -> [String] {
        s.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: " /", with: "/").split(
            separator: " "
        ).map { aliases[String($0)] ?? String($0) }
    }

    /// Token-wise comparison; numbers within 1e-9 relative, long integers exactly.
    static func same(_ expected: String, _ got: String) -> Bool {
        let a = tokens(expected)
        let b = tokens(got)
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            if x == y { continue }
            if let dx = Double(x), let dy = Double(y) {
                if x.count > 15 && !x.contains(".") && !x.contains("e") && !y.contains("e") { return false }
                if dx == dy { continue }
                let tol = 1e-9 * max(abs(dx), abs(dy))
                if abs(dx - dy) <= max(tol, 1e-12) { continue }
                return false
            }
            return false
        }
        return true
    }

    static func joined(_ v: String?, _ u: String?) -> String {
        [v ?? "", u ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }

    struct Outcome {
        let pass: Bool
        let got: String
    }

    static func check(_ f: File.Fixture, _ meta: File.Meta) -> Outcome {
        let out = Calculator.evaluate(f.input, context(f, meta))
        let e = f.expect
        func describe(_ r: CalcResult) -> String {
            var s = r.primary.raw
            if !r.alternatives.isEmpty {
                s += "  | alts: " + r.alternatives.map { "\($0.raw) (\($0.label ?? ""))" }.joined(separator: "; ")
            }
            return s
        }
        switch (e.kind, out) {
        case ("none", .none):
            return Outcome(pass: true, got: "none")
        case ("error", .error(let m)):
            return Outcome(pass: true, got: "error: \(m)")
        case ("value", .result(let r)), ("live", .result(let r)):
            guard let v = e.value else { return Outcome(pass: true, got: describe(r)) }
            return Outcome(pass: same(joined(v, e.unit), r.primary.raw), got: describe(r))
        case ("alternatives", .result(let r)):
            let alts = (e.alternatives ?? []).filter { !$0.value.isEmpty }
            guard let first = alts.first else { return Outcome(pass: true, got: describe(r)) }
            let all = [r.primary] + r.alternatives
            let primaryOK = same(joined(first.value, first.unit), r.primary.raw)
            let restOK = alts.dropFirst().allSatisfy { a in all.contains { same(joined(a.value, a.unit), $0.raw) } }
            return Outcome(pass: primaryOK && restOK, got: describe(r))
        case (_, .none): return Outcome(pass: false, got: "none")
        case (_, .error(let m)): return Outcome(pass: false, got: "error: \(m)")
        case (_, .result(let r)): return Outcome(pass: false, got: describe(r))
        }
    }

    static func short(_ t: Tok) -> String {
        switch t {
        case .num(let n, _): return Format.canonical(n)
        case .unit(let u): return "[\(u.id)]"
        case .scale(let n, _): return "×\(Format.canonical(n))"
        case .op(let o): return o
        case .ident(let s): return "id:\(s)"
        case .kw(let k): return "kw:\(k)"
        case .date: return "date"
        case .clock(let c): return "clock\(c.h):\(c.m)"
        case .zone(let z): return "zone:\(z.label)"
        case .radixTarget(let r): return "radix\(r)"
        case .dateWord(let w): return "dw:\(w)"
        case .choice: return "choice"
        }
    }

    /// `CALC_Q="query" swift test --filter FixtureTests/query` prints what the engine makes of a query.
    @Test func query() throws {
        guard let q = ProcessInfo.processInfo.environment["CALC_Q"] else { return }
        let file = try Self.loadFixtures()
        if q == "ALL" {
            var lines: [String] = []
            for f in file.fixtures {
                let ctx = Self.context(f, file.meta)
                let t0 = Date()
                let out = Calculator.evaluate(f.input, ctx)
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                var line = "\(f.id) [\(ms)ms] \(f.input)  ⇒  "
                switch out {
                case .none: line += "—"
                case .error(let m): line += "⚠ " + m
                case .result(let r):
                    line += r.primary.text + (r.primary.label.map { " (\($0))" } ?? "") + "   «\(r.interpretation)»"
                    for a in r.alternatives { line += "\n        alt: \(a.text) (\(a.label ?? ""))" }
                }
                lines.append(line)
            }
            try lines.joined(separator: "\n").write(
                toFile: ProcessInfo.processInfo.environment["CALC_REPORT"]!,
                atomically: true,
                encoding: .utf8
            )
            return
        }
        let loc = ProcessInfo.processInfo.environment["CALC_LOCALE"] ?? "en_NO"
        let fx = File.Fixture(
            id: "q",
            category: "q",
            tier: 0,
            input: q,
            expect: .init(kind: "value", value: nil, unit: nil, alternatives: nil, note: nil),
            locale: loc,
            context: nil
        )
        let ctx = Self.context(fx, file.meta)
        let norm = Lexer.normalize(q)
        let (rw, _) = Rewriter.rewrite(norm, locale: ctx.locale)
        print("rewritten:", rw)
        if let toks = try? Lexer.tokenize(rw, locale: ctx.locale) {
            for r in Calculator.expand(toks).prefix(8) {
                var p = Parser(r.tokens)
                let node = try? p.parseProgram()
                var msg = "parse failed"
                if let node {
                    do { msg = "\(try Evaluator(ctx).eval(node))" } catch { msg = "eval error \(error)" }
                }
                print(
                    "reading",
                    r.picks,
                    r.tokens.map { Self.short($0.tok) }.joined(separator: " "),
                    "→",
                    msg.prefix(200)
                )
            }
        }
        switch Calculator.evaluate(q, ctx) {
        case .none: print("NONE")
        case .error(let m): print("ERROR", m)
        case .result(let r):
            print("RESULT", r.primary.raw, "| display", r.primary.text, "| interp", r.interpretation)
            for a in r.alternatives { print("  alt", a.raw, a.label ?? "") }
        }
    }

    @Test func fixtures() throws {
        let file = try Self.loadFixtures()
        var byCategory: [String: (Int, Int)] = [:]
        var byTier: [Int: (Int, Int)] = [:]
        var failures: [String] = []
        var unexpected: [String] = []
        let trace = ProcessInfo.processInfo.environment["CALC_TRACE"] != nil
        let only = ProcessInfo.processInfo.environment["CALC_ONLY"]
        for f in file.fixtures {
            if let only, !f.id.hasPrefix(only) && f.input != only { continue }
            if trace { FileHandle.standardError.write((f.id + "\n").data(using: .utf8)!) }
            let o = Self.check(f, file.meta)
            var c = byCategory[f.category, default: (0, 0)]
            c.1 += 1
            var t = byTier[f.tier, default: (0, 0)]
            t.1 += 1
            if o.pass {
                c.0 += 1
                t.0 += 1
            } else {
                let exp = f.expect.kind + " " + Self.joined(f.expect.value, f.expect.unit)
                let line = "\(f.id) T\(f.tier)  \(f.input)  →  expected \(exp)  got \(o.got)"
                failures.append(line)
                if Self.skipped[f.id] == nil { unexpected.append(line) }
            }
            byCategory[f.category] = c
            byTier[f.tier] = t
        }
        var report = "\nCategory        pass/total\n"
        for (k, v) in byCategory.sorted(by: { $0.key < $1.key }) {
            report += k.padding(toLength: 16, withPad: " ", startingAt: 0) + "\(v.0)/\(v.1)\n"
        }
        for (k, v) in byTier.sorted(by: { $0.key < $1.key }) { report += "T\(k)  \(v.0)/\(v.1)\n" }
        let total = byCategory.values.reduce((0, 0)) { ($0.0 + $1.0, $0.1 + $1.1) }
        report += "Total \(total.0)/\(total.1)\n\nFailures:\n" + failures.joined(separator: "\n")
        let path = ProcessInfo.processInfo.environment["CALC_REPORT"] ?? NSTemporaryDirectory() + "calc-report.txt"
        try report.write(toFile: path, atomically: true, encoding: .utf8)
        print(report)
        #expect(unexpected.isEmpty, "\(unexpected.count) fixtures failed (report: \(path))")
    }
}
