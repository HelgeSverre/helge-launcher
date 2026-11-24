import Foundation
import Testing

@testable import HelgeLauncher

@Suite struct StatsTests {
    func history() -> History {
        History(url: FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).json"))
    }

    @Test func recordsCountsPerDayAndForgets() {
        let h = history()
        let now = Date()
        h.record("app:/Applications/Slack.app", at: now.addingTimeInterval(-86400))
        h.record("app:/Applications/Slack.app", at: now)
        h.record("emoji:🎉", at: now)
        #expect(h.entries["app:/Applications/Slack.app"]?.count == 2)
        #expect(h.entries["app:/Applications/Slack.app"]?.days?.count == 2)
        let s = UsageSummary(h.entries, now: now)
        #expect(s.total == 3 && s.items == 2 && s.today == 2 && s.week == 3 && s.daily.count == 30)
        #expect(s.categories.first?.0 == .apps && s.categories.first?.1 == 2)
        h.forget("emoji:🎉")
        #expect(h.entries["emoji:🎉"] == nil)
    }

    @Test func oldEntriesHaveNoDailyChart() {
        let s = UsageSummary(["mode.emoji": History.Entry(count: 5, last: 0)])
        #expect(s.daily.isEmpty && s.today == 0 && s.categories.first?.0 == .launcher)
    }

    @Test @MainActor func categoriesAndLabels() {
        #expect(UsageCategory(key: "cleanshot.capture-area") == .cleanshot)
        #expect(UsageCategory(key: "op:abc") == .passwords)
        #expect(UsageCategory(key: "cmd:Deploy") == .commands)
        #expect(Launcher.grouped(16554) == "16\u{00A0}554")
        let now = Date()
        #expect(Launcher.ago(now.addingTimeInterval(-300), now: now) == "5m")
        #expect(Launcher.ago(now.addingTimeInterval(-3 * 86400), now: now) == "3d")
        #expect(Launcher.ago(now.addingTimeInterval(-90 * 86400), now: now) == "3mo")
    }

    @Test @MainActor func goneItemsAreNamedFromTheKey() {
        #expect(Launcher.unlisted("app:/Applications/Gone App.app").title == "Gone App")
        #expect(Launcher.unlisted("snippet:sig").title == "Sig")
    }
}
