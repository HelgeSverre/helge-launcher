import Calc
import Foundation
import Testing

@testable import HelgeLauncher

@MainActor
struct CalculatorRowTests {
    func launcher(_ query: String, locale: String = "en_US") -> Launcher {
        let l = Launcher()
        var cfg = Config()
        cfg.calculator.locale = locale
        l.apply(cfg)
        l.query = query
        return l
    }

    @Test func answerComesFirstAndIsSelected() {
        let l = launcher("2 + 2")
        let items = l.computeItems()
        #expect(items.first?.calc?.style == .result)
        #expect(items.first?.title == "4")
        l.setItems(items, keepSelection: false)
        #expect(l.selected == 0)
        #expect(l.current?.actions.map(\.title) == ["Copy", "Copy Number", "Paste"])
    }

    @Test func otherReadingsFollowAsRows() {
        let items = launcher("1 gallon in liters").computeItems()
        #expect(items[0].calc?.detail == "US gallon")
        #expect(items[1].title == "4.54609 L")
        #expect(items[1].subtitle == "imperial gallon")
    }

    @Test func notACalculationAddsNothing() {
        for q in ["iPhone 15", "1Password", "365", "10 km"] {
            #expect(launcher(q).computeItems().allSatisfy { !$0.id.hasPrefix("calc") }, "\(q)")
        }
    }

    @Test func errorRowIsNotSelected() {
        let l = launcher("5 km + 3 kg")
        let items = l.computeItems()
        #expect(items.first?.calc?.style == .error)
        l.setItems(items, keepSelection: false)
        #expect(l.selected == 1)
    }

    @Test func disabledCalculatorAddsNothing() {
        let l = Launcher()
        var cfg = Config()
        cfg.calculator.enabled = false
        l.apply(cfg)
        l.query = "2 + 2"
        #expect(!l.computeItems().contains { $0.id.hasPrefix("calc") })
    }

    @Test func copyNumberUsesTheLocaleDecimalMark() {
        let items = launcher("1/8", locale: "nb_NO").computeItems()
        #expect(items.first?.title == "0,125")
        #expect(items.first?.actions[1].detail == "copy 0,125")
    }

    @Test func norgesBankCSVIsScaledByTheUnitMultiplier() {
        let csv = """
            FREQ;Frequency;BASE_CUR;Base Currency;QUOTE_CUR;Quote Currency;TENOR;Tenor;DECIMALS;CALCULATED;UNIT_MULT;Unit Multiplier;COLLECTION;Collection Indicator;TIME_PERIOD;OBS_VALUE
            B;Business;USD;US dollar;NOK;Norwegian krone;SP;Spot;4;false;0;Units;C;ECB concertation time 14:15 CET;2026-11-20;9.7525
            B;Business;SEK;Swedish krona;NOK;Norwegian krone;SP;Spot;2;false;2;Hundreds;C;ECB concertation time 14:15 CET;2026-11-20;95.59
            B;Business;RUB;Russian rouble;NOK;Norwegian krone;SP;Spot;3;false;2;Hundreds;C;ECB concertation time 14:15 CET;2022-03-01;8.413
            """
        let s = Rates.parseNorgesBank(csv)
        #expect(s.date == "2026-11-20")
        #expect(s.nokPer["USD"] == "9.7525")
        #expect(s.nokPer["SEK"] == "0.9559")
        #expect(s.nokPer["RUB"] == nil)
    }

    @Test func chainsShowTheirSteps() {
        let l = launcher("500 km at 6 l/100km at 21 kr/l in eur")
        l.setItems(l.computeItems(), keepSelection: false)
        let steps = l.current?.calc?.steps ?? []
        #expect(steps.map(\.operation) == ["500 km", "@ 6 L ÷ 100 km", "@ 21 NOK/L", "→ EUR"])
        #expect(steps.map(\.result).prefix(3) == ["500 km", "30 L", "630 NOK"])
        #expect(l.current?.actions.last?.title == "Show Steps")
        l.toggleSteps()
        #expect(l.showSteps)
        l.query = "2 + 2"
        #expect(!l.showSteps)
        #expect(launcher("2 + 2").computeItems().first?.calc?.steps.isEmpty == true)
    }
}
