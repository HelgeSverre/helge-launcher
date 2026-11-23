import AppKit
import Calc

/// What a calculator row shows.
struct CalcCard {
    enum Style {
        case result
        case error
    }

    var style: Style
    /// The query as understood; nil when it would only repeat the query.
    var expression: String?
    /// The answer, or the reason there is none.
    var answer: String
    /// Which reading this is and where/when a time is, beside the answer.
    var detail: String?
    /// The worked chain, shown with ⌘I.
    var steps: [CalcStep] = []
}

/// Exchange rates: Norges Bank for fiat, CoinGecko for crypto, cached in the support directory.
@MainActor
final class Rates {
    static let shared = Rates()

    private(set) var table: RateTable?
    private var fetchedAt: Date?
    private var fetching = false
    private let file = Paths.supportDir.appendingPathComponent("rates.json")

    struct Stored: Codable {
        var date: String
        var fetched: Date
        var nokPer: [String: String]
    }

    /// Norges Bank fixing of 20 Nov 2026; used until the first fetch succeeds.
    static let seed = Stored(
        date: "2026-11-20",
        fetched: .distantPast,
        nokPer: [
            "USD": "9.7525", "EUR": "10.718", "GBP": "12.7999", "SEK": "0.9559", "DKK": "1.4339", "JPY": "0.061474",
            "CHF": "11.6209", "CAD": "6.8168", "AUD": "6.5009", "BTC": "597184.585", "ETH": "16809.70158",
        ]
    )

    init() {
        let stored =
            (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Rates.seed
        apply(stored)
    }

    private func apply(_ s: Stored) {
        table = RateTable(nokPer: s.nokPer, date: s.date)
        fetchedAt = s.fetched
    }

    /// Fetches in the background when the cache is older than six hours.
    func refreshIfStale(enabled: Bool) {
        guard enabled, !fetching, !Paths.isTestRunner else { return }
        if let f = fetchedAt, Date().timeIntervalSince(f) < 6 * 3600 { return }
        fetching = true
        Task {
            defer { fetching = false }
            if let s = await Rates.fetch() {
                apply(s)
                try? JSONEncoder().encode(s).write(to: file, options: .atomic)
            } else {
                // Try again in an hour, not on every keystroke.
                fetchedAt = Date().addingTimeInterval(-5 * 3600)
            }
        }
    }

    nonisolated static func fetch() async -> Stored? {
        let nb = URL(
            string:
                "https://data.norges-bank.no/api/data/EXR/B..NOK.SP?format=csv&lastNObservations=1&locale=en&bom=exclude"
        )!
        let cg = URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum&vs_currencies=nok")!
        async let fiat = try? URLSession.shared.data(from: nb).0
        async let crypto = try? URLSession.shared.data(from: cg).0
        guard let csv = await fiat.flatMap({ String(data: $0, encoding: .utf8) }) else { return nil }
        var s = parseNorgesBank(csv)
        guard !s.nokPer.isEmpty else { return nil }
        if let data = await crypto,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Double]]
        {
            if let btc = json["bitcoin"]?["nok"] { s.nokPer["BTC"] = String(btc) }
            if let eth = json["ethereum"]?["nok"] { s.nokPer["ETH"] = String(eth) }
        }
        return s
    }

    /// `BASE_CUR` is field 3, `UNIT_MULT` (a power of ten) 11, `TIME_PERIOD` 15, `OBS_VALUE` 16.
    /// Series that stopped (older than ten days before the newest) are left out.
    nonisolated static func parseNorgesBank(_ csv: String) -> Stored {
        var rows: [(code: String, date: String, value: Decimal)] = []
        for line in csv.split(whereSeparator: \.isNewline).dropFirst() {
            let f = line.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 16, let mult = Int(f[10]),
                let v = Decimal(string: f[15], locale: Locale(identifier: "en_US"))
            else { continue }
            var scale = Decimal(1)
            for _ in 0..<max(0, mult) { scale *= 10 }
            rows.append((f[2], f[14], v / scale))
        }
        let newest = rows.map(\.date).max() ?? ""
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        let cutoff = f.date(from: newest).map { f.string(from: $0.addingTimeInterval(-10 * 86400)) } ?? ""
        var out: [String: String] = [:]
        for r in rows where r.date >= cutoff { out[r.code] = NSDecimalNumber(decimal: r.value).stringValue }
        return Stored(date: newest, fetched: Date(), nokPer: out)
    }
}

/// Calculator rows for the root search.
enum CalcProvider {
    @MainActor
    static func context(_ cfg: CalculatorConfig, previous: CalcAnswer?) -> CalcContext {
        let locale = cfg.locale == "system" ? CalcLocale.system() : CalcLocale(identifier: cfg.locale)
        return CalcContext(
            locale: locale,
            now: Date(),
            timeZone: .current,
            rates: Rates.shared.table,
            previousAnswer: previous
        )
    }

    /// The answer first, then other readings; an error row when the query is a calculation without an answer.
    @MainActor
    static func items(
        _ query: String,
        _ cfg: CalculatorConfig,
        previous: CalcAnswer?,
        used: @escaping (CalcAnswer) -> Void
    ) -> [Item] {
        switch Calculator.evaluate(query, context(cfg, previous: previous)) {
        case .none:
            return []
        case .error(let message):
            return [
                Item(
                    id: "calc.error",
                    title: message,
                    icon: .symbol("exclamationmark.triangle"),
                    calc: CalcCard(style: .error, expression: nil, answer: message)
                )
            ]
        case .result(let r):
            let main = item(r.primary, id: "calc", used: used)
            var first = main
            first.calc = CalcCard(
                style: .result,
                expression: r.showsInterpretation ? r.interpretation : nil,
                answer: r.primary.text,
                detail: [r.primary.label, r.primary.detail].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                steps: r.steps
            )
            if !r.steps.isEmpty {
                first.actions.append(
                    Action(title: "Show Steps", detail: "\(r.steps.count) steps") {
                        Launcher.shared?.toggleSteps()
                        return .stay
                    }
                )
            }
            return [first]
                + r.alternatives.prefix(4).enumerated().map { i, a in item(a, id: "calc.alt\(i)", used: used) }
        }
    }

    @MainActor
    private static func item(_ a: CalcAnswer, id: String, used: @escaping (CalcAnswer) -> Void) -> Item {
        Item(
            id: id,
            title: a.text,
            subtitle: [a.label, a.detail].compactMap { $0 }.joined(separator: " · "),
            icon: .symbol("equal"),
            actions: [
                Action(title: "Copy", detail: "copy \(a.text)") {
                    used(a)
                    Pasteboard.copy(a.text)
                    return .close
                },
                Action(title: "Copy Number", detail: "copy \(a.plain)") {
                    used(a)
                    Pasteboard.copy(a.plain)
                    return .close
                },
                Action(title: "Paste", detail: "paste \(a.text)") {
                    used(a)
                    Pasteboard.paste(a.text)
                    return .close
                },
            ]
        )
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
