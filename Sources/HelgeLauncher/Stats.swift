import AppKit
import SwiftUI

/// What kind of thing a history key counts, for grouping and colour.
enum UsageCategory: CaseIterable {
    case apps, cleanshot, launcher, commands, snippets, emoji, passwords

    init(key: String) {
        switch true {
        case key.hasPrefix("app:"): self = .apps
        case key.hasPrefix("cleanshot."): self = .cleanshot
        case key.hasPrefix("mode."), key.hasPrefix("plugin:"), key.hasPrefix("hl."): self = .launcher
        case key.hasPrefix("snippet:"): self = .snippets
        case key.hasPrefix("emoji:"): self = .emoji
        case key.hasPrefix("op:"): self = .passwords
        default: self = .commands
        }
    }

    var title: String {
        switch self {
        case .apps: return "Apps"
        case .cleanshot: return "CleanShot"
        case .launcher: return "Launcher"
        case .commands: return "Commands"
        case .snippets: return "Snippets"
        case .emoji: return "Emoji"
        case .passwords: return "1Password"
        }
    }

    var color: Color {
        switch self {
        case .apps: return Theme.accentText
        case .cleanshot: return Theme.synType
        case .launcher: return Theme.synFunction
        case .commands: return Theme.synString
        case .snippets: return Theme.synRemoved
        case .emoji: return Theme.synNumber
        case .passwords: return Theme.text2
        }
    }
}

/// One row's numbers in the statistics.
struct Usage {
    /// Place by count among everything used, from 1.
    var rank: Int
    var count: Int
    /// Count relative to the most used item, 0…1.
    var share: Double
    var category: UsageCategory
}

/// Totals over the whole history.
struct UsageSummary {
    var total = 0
    var items = 0
    var today = 0
    var week = 0
    /// Launches per category, largest first.
    var categories: [(UsageCategory, Int)] = []
    /// Launches per day for the last 30 days, oldest first; empty before any day was recorded.
    var daily: [Int] = []

    init(_ entries: [String: History.Entry], now: Date = Date()) {
        var byCategory: [UsageCategory: Int] = [:]
        var perDay: [String: Int] = [:]
        for (key, e) in entries {
            total += e.count
            byCategory[UsageCategory(key: key), default: 0] += e.count
            for (d, n) in e.days ?? [:] { perDay[d, default: 0] += n }
        }
        items = entries.count
        categories = byCategory.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        let days = (0..<30).reversed().map { History.day(now.addingTimeInterval(-Double($0) * 86400)) }
        today = perDay[days[29]] ?? 0
        week = days.suffix(7).reduce(0) { $0 + (perDay[$1] ?? 0) }
        if !perDay.isEmpty { daily = days.map { perDay[$0] ?? 0 } }
    }
}

extension Launcher {
    /// Everything in the history, most used first. Rows keep the item's own actions, so ↵ opens it.
    func statsItems() -> [Item] {
        var known: [String: Item] = [:]
        for it in rootItems + Emoji.items + OnePassword.shared.items {
            if let k = it.historyKey, known[k] == nil { known[k] = it }
        }
        let entries = History.shared.entries.sorted {
            $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.value.last > $1.value.last
        }
        let most = Double(max(1, entries.first?.value.count ?? 1))
        let q = query.trimmingCharacters(in: .whitespaces)
        var out: [Item] = []
        for (i, (key, e)) in entries.enumerated() {
            let category = UsageCategory(key: key)
            var it = known[key] ?? Launcher.unlisted(key)
            it.id = "stats:" + key
            it.subtitle = category.title
            it.keywords.append(category.title)
            it.accessory = Launcher.ago(Date(timeIntervalSince1970: e.last))
            it.usage = Usage(rank: i + 1, count: e.count, share: Double(e.count) / most, category: category)
            it.actions.append(
                Action(title: "Forget") { [weak self] in
                    History.shared.forget(key)
                    self?.toast("Forgot \(it.title)")
                    return .stay
                }
            )
            if !q.isEmpty && Fuzzy.best(q, it) == nil { continue }
            out.append(it)
        }
        return out
    }

    /// A history key whose item is gone (an uninstalled app, a removed snippet): named from the key.
    static func unlisted(_ key: String) -> Item {
        let (prefix, rest): (String, String) = {
            if let i = key.firstIndex(of: ":") { return (String(key[..<i]), String(key[key.index(after: i)...])) }
            if let i = key.firstIndex(of: ".") { return (String(key[..<i]), String(key[key.index(after: i)...])) }
            return ("", key)
        }()
        var it = Item(id: key, title: rest)
        switch prefix {
        case "app":
            it.title = URL(fileURLWithPath: rest).deletingPathExtension().lastPathComponent
            it.icon = FileManager.default.fileExists(atPath: rest) ? .file(rest) : .symbol("app.dashed")
        case "emoji":
            it.icon = .emoji(rest)
        default:
            it.title = rest.replacingOccurrences(of: "-", with: " ").capitalized
            it.icon = .symbol("questionmark.square.dashed")
        }
        it.actions = [
            Action(title: "Open") { [weak self = Launcher.shared] in
                self?.toast("\(it.title) is no longer available")
                return .stay
            }
        ]
        return it
    }

    /// "now", "5m", "3h", "2d", "3w", "4mo", "2y".
    static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(d))
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(Int(s / 60))m"
        case ..<86400: return "\(Int(s / 3600))h"
        case ..<(14 * 86400): return "\(Int(s / 86400))d"
        case ..<(60 * 86400): return "\(Int(s / (7 * 86400)))w"
        case ..<(365 * 86400): return "\(Int(s / (30 * 86400)))mo"
        default: return "\(Int(s / (365 * 86400)))y"
        }
    }

    /// 14230 → "14 230".
    static func grouped(_ n: Int) -> String {
        var out = ""
        for (i, ch) in String(n).reversed().enumerated() {
            if i > 0 && i % 3 == 0 { out.append("\u{00A0}") }
            out.append(ch)
        }
        return String(out.reversed())
    }
}

// MARK: - Views

/// Totals, the split by category and (once days are recorded) the last 30 days.
struct StatsSummary: View {
    let summary: UsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 26) {
                figure(summary.total, "launches")
                figure(summary.items, "items")
                if !summary.daily.isEmpty {
                    figure(summary.today, "today")
                    figure(summary.week, "last 7 days")
                }
                Spacer(minLength: 12)
                if !summary.daily.isEmpty { daily }
            }
            categoryBar
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
    }

    private func figure(_ n: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Launcher.grouped(n)).font(Theme.sans(22, .semibold).monospacedDigit()).foregroundStyle(Theme.text)
            Text(label).font(Theme.sans(11.5)).foregroundStyle(Theme.muted)
        }
    }

    private var daily: some View {
        let top = Double(max(1, summary.daily.max() ?? 1))
        return VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(summary.daily.enumerated()), id: \.offset) { i, n in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(n == 0 ? Theme.border : (i == summary.daily.count - 1 ? Theme.accentText : Theme.text2))
                        .frame(width: 5, height: n == 0 ? 2 : max(3, 30 * Double(n) / top))
                }
            }
            .frame(height: 30, alignment: .bottom)
            Text("last 30 days").font(Theme.sans(11.5)).foregroundStyle(Theme.muted)
        }
    }

    private var categoryBar: some View {
        let total = Double(max(1, summary.total))
        return VStack(alignment: .leading, spacing: 7) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(summary.categories, id: \.0) { c, n in
                        Rectangle().fill(c.color).frame(
                            width: max(2, (g.size.width - 2 * Double(summary.categories.count - 1)) * Double(n) / total)
                        )
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 6)
            HStack(spacing: 14) {
                ForEach(summary.categories, id: \.0) { c, n in
                    HStack(spacing: 5) {
                        Circle().fill(c.color).frame(width: 7, height: 7)
                        Text(c.title).foregroundStyle(Theme.text2)
                        Text(percent(Double(n) / total)).foregroundStyle(Theme.muted).monospacedDigit()
                    }
                }
            }
            .font(Theme.sans(11.5))
            .lineLimit(1)
        }
    }

    private func percent(_ x: Double) -> String {
        x >= 0.0995 ? "\(Int((x * 100).rounded()))%" : (x >= 0.01 ? String(format: "%.1f%%", x * 100) : "<1%")
    }
}

/// A row: rank, icon, name, a bar of its share of the most used item, count and when last used.
struct StatsRow: View {
    let item: Item
    let usage: Usage
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("\(usage.rank)")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.muted)
                .frame(width: 24, alignment: .trailing)
            IconView(icon: item.icon, selected: selected).frame(width: 22, height: 22)
            Text(item.title)
                .font(Theme.sans(14, selected ? .medium : .regular))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text(item.subtitle).font(Theme.sans(12.5)).foregroundStyle(Theme.muted).lineLimit(1)
            Spacer(minLength: 12)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border)
                Capsule().fill(usage.category.color.opacity(selected ? 1 : 0.8))
                    .frame(width: max(4, 130 * usage.share))
            }
            .frame(width: 130, height: 5)
            Text(Launcher.grouped(usage.count))
                .font(Theme.sans(13, .medium).monospacedDigit())
                .foregroundStyle(Theme.text)
                .frame(width: 52, alignment: .trailing)
            Text(item.accessory)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.muted)
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: Theme.radiusRow).fill(selected ? Theme.accentSoft : .clear))
    }
}
