import Foundation
import Testing

@testable import Calc

/// Time zones named by state, country or "<place> time".
struct ZoneTests {
    let ctx = CalcContext(
        locale: .en,
        now: ISO8601DateFormatter().date(from: "2026-11-23T12:00:00+01:00")!,
        timeZone: TimeZone(identifier: "Europe/Oslo")!
    )

    func canonical(_ q: String) -> String? { Calculator.evaluate(q, ctx).result?.primary.canonical }

    @Test func statesAndCountries() {
        #expect(canonical("12am texas in norway") == "2026-11-23T07:00:00+01:00")
        #expect(canonical("12am texas time in norway") == "2026-11-23T07:00:00+01:00")
        #expect(canonical("9am california in oslo") == "2026-11-23T18:00:00+01:00")
        #expect(canonical("2pm germany in japan") == "2026-11-23T22:00:00+09:00")
        #expect(canonical("time in texas") == "2026-11-23T05:00:00-06:00")
        #expect(canonical("9am chile in oslo") != nil)
    }

    @Test func aClockWithoutAZoneIsLocal() {
        #expect(canonical("3pm in texas") == "2026-11-23T08:00:00-06:00")
    }
}

/// Arithmetic after a conversion applies to the converted result.
struct ConversionArithmeticTests {
    let ctx = CalcContext(locale: .en, rates: RateTable(nokPer: ["USD": "9.7525"], date: "2026-11-20"))

    func raw(_ q: String) -> String? { Calculator.evaluate(q, ctx).result?.primary.raw }

    @Test func operatorsAfterTheTarget() {
        #expect(raw("1 usd in nok / 10") == "0.97525 NOK")
        #expect(raw("100 usd in nok * 2") == "1950.5 NOK")
        #expect(raw("8 l/100km in l/100 km") == "8 L/100 km")  // a number then a unit stays in the target
    }
}
