import SwiftUI

// MARK: - Rows

/// Processes, leftovers, ports and storage rows: name on the left, a bar and figures on the right.
struct SystemRowView: View {
    let item: Item
    let row: SystemRow
    let selected: Bool

    var body: some View {
        switch row {
        case .portAnswer(let port, let facts, let folder):
            PortAnswerCard(item: item, port: port, facts: facts, folder: folder, selected: selected)
        case .process(let cwd, let ports, let age, let cpu, let memory, let sort):
            HStack(spacing: 10) {
                Text(item.title).font(Theme.sans(13)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                if let cwd {
                    Text(cwd).font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.head)
                }
                PortChips(ports: ports)
                Spacer(minLength: 8)
                Text(age).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                Text(sort == .memory ? Fmt.memory(memory) : Fmt.percent(cpu))
                    .font(Theme.sans(12.5).monospacedDigit())
                    .foregroundStyle(Theme.text2)
                    .frame(width: 60, alignment: .trailing)
            }
            .padding(.leading, 44).padding(.trailing, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: Theme.radiusRow).fill(selected ? Theme.accentSoft : .clear))
        default:
            HStack(spacing: 12) {
                IconView(icon: item.icon, selected: selected).frame(width: 22, height: 22)
                Text(item.title)
                    .font(Theme.sans(14, selected ? .medium : .regular))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let n = count, n > 1 { Text(verbatim: "×\(n)").font(Theme.mono(11)).foregroundStyle(Theme.muted) }
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(Theme.sans(12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                        .truncationMode(.head)
                }
                trailing
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: Theme.radiusRow).fill(selected ? Theme.accentSoft : .clear))
        }
    }

    private var count: Int? {
        switch row {
        case .group(let n, _, _, _, _, _, _), .leftover(let n, _, _, _): return n
        default: return nil
        }
    }

    @ViewBuilder private var trailing: some View {
        switch row {
        case .group(_, let cpu, let memory, let disk, let network, let share, let sort):
            Spacer(minLength: 8)
            Bar(share: share, color: sort == .memory ? Theme.synType : Theme.accentText).frame(width: 110)
            Text(primary(sort, cpu: cpu, memory: memory, disk: disk, network: network))
                .font(Theme.sans(13, .medium).monospacedDigit())
                .foregroundStyle(Theme.text)
                .frame(width: 66, alignment: .trailing)
            Text(sort == .cpu ? Fmt.memory(memory) : Fmt.percent(cpu))
                .font(Theme.sans(12.5).monospacedDigit())
                .foregroundStyle(Theme.text2)
                .frame(width: 58, alignment: .trailing)
        case .leftover(_, let age, let memory, let ports):
            PortChips(ports: ports)
            Spacer(minLength: 8)
            Text(age).font(Theme.mono(11)).foregroundStyle(Theme.muted)
            Text(Fmt.memory(memory))
                .font(Theme.sans(13, .medium).monospacedDigit())
                .foregroundStyle(Theme.text)
                .frame(width: 66, alignment: .trailing)
        case .port(let ports, let folder, let age):
            if let folder {
                Text(folder).font(Theme.mono(11.5)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            PortChips(ports: ports, accent: selected)
            Text(age).font(Theme.mono(11)).foregroundStyle(Theme.muted).frame(width: 58, alignment: .trailing)
        case .storage(let path, let bytes, let share, let tag):
            Text(path).font(Theme.mono(11.5)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 8)
            Text(tag)
                .font(Theme.sans(11))
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.borderStrong, lineWidth: 1)
                )
            Bar(share: share, color: Theme.synNumber).frame(width: 110)
            Text(bytes.map(Fmt.bytes) ?? "…")
                .font(Theme.sans(13, .medium).monospacedDigit())
                .foregroundStyle(Theme.text)
                .frame(width: 66, alignment: .trailing)
        default:
            EmptyView()
        }
    }

    private func primary(_ s: ProcSort, cpu: Double, memory: UInt64, disk: Double, network: Double) -> String {
        switch s {
        case .cpu: return Fmt.percent(cpu)
        case .memory: return Fmt.memory(memory)
        case .disk: return Fmt.rate(disk)
        case .network: return Fmt.rate(network)
        }
    }
}

struct Bar: View {
    let share: Double
    let color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border)
                Capsule().fill(color.opacity(0.85)).frame(width: max(share > 0 ? 3 : 0, g.size.width * min(1, share)))
            }
        }
        .frame(height: 5)
    }
}

struct PortChips: View {
    let ports: [Int]
    var accent = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(ports.prefix(4), id: \.self) { p in
                Text(verbatim: ":\(p)")
                    .font(Theme.mono(11))
                    .foregroundStyle(accent ? Theme.accentText : Theme.note)
                    .padding(.horizontal, 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.borderStrong, lineWidth: 1)
                    )
            }
        }
    }
}

/// The main search's answer for a port, drawn like the calculator card.
struct PortAnswerCard: View {
    let item: Item
    let port: Int
    let facts: String?
    let folder: String?
    let selected: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let facts {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: "localhost:\(port)").font(Theme.mono(12)).foregroundStyle(Theme.muted)
                    Spacer(minLength: 12)
                    Text(item.title)
                        .font(Theme.sans(26, .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(facts).font(Theme.sans(12)).foregroundStyle(Theme.text2).lineLimit(1)
                    Spacer(minLength: 12)
                    if let folder {
                        Text(folder).font(Theme.mono(12)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(
                            .head
                        )
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "network.slash").foregroundStyle(Theme.muted)
                    Text(item.title).font(Theme.sans(13)).foregroundStyle(Theme.text2)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: facts == nil ? 40 : 84)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: Theme.radiusRow).fill(selected ? Theme.raised : Theme.soft))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusRow)
                .strokeBorder(selected && facts != nil ? Theme.accentText.opacity(0.55) : Theme.border, lineWidth: 1)
        )
        .padding(.bottom, 4)
    }
}

// MARK: - Headers

/// CPU, memory, disk and battery above the processes list, and the leftovers banner.
struct SystemStrip: View {
    let stats: SystemStats
    let leftovers: (count: Int, memory: UInt64)

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                cell(
                    "CPU",
                    Fmt.percent(stats.cpu),
                    note: String(format: "load %.1f · %d cores", stats.load, stats.cores.count)
                ) {
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(Array(stats.cores.enumerated()), id: \.offset) { _, c in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(c < 3 ? Theme.borderStrong : Theme.text2)
                                .frame(height: max(2, 16 * c / 100))
                        }
                    }
                    .frame(height: 16, alignment: .bottom)
                }
                cell(
                    "Memory",
                    "\(Fmt.memory(stats.memoryUsed)) / \(Fmt.memory(stats.memoryTotal))",
                    note: "pressure \(pressure) · swap \(Fmt.memory(stats.swapUsed))",
                    tint: stats.pressure > 1 ? Theme.warn : nil
                ) {
                    Bar(
                        share: Double(stats.memoryUsed) / Double(max(1, stats.memoryTotal)),
                        color: stats.pressure > 1 ? Theme.warn : Theme.synType
                    )
                    .padding(.vertical, 5)
                }
                cell(
                    "Disk",
                    "\(Fmt.bytes(stats.diskFree)) free",
                    note: "of \(Fmt.bytes(stats.diskTotal))",
                    tint: lowDisk ? Theme.synNumber : nil
                ) {
                    Bar(
                        share: 1 - Double(stats.diskFree) / Double(max(1, stats.diskTotal)),
                        color: lowDisk ? Theme.synNumber : Theme.text2
                    )
                    .padding(.vertical, 5)
                }
                if let b = stats.battery {
                    cell("Battery", "\(b)%", note: (stats.onPower ? "on power" : "on battery") + " · up \(uptime)") {
                        Bar(share: Double(b) / 100, color: b < 20 ? Theme.err : Theme.synString).padding(.vertical, 5)
                    }
                } else {
                    cell("Uptime", uptime, note: "") { Color.clear.frame(height: 16) }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            if leftovers.count > 0 {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(
                        Theme.synNumber
                    )
                    Text("\(leftovers.count) leftover dev \(leftovers.count == 1 ? "process" : "processes")")
                        .foregroundStyle(Theme.text)
                    Text("not in use · \(Fmt.memory(leftovers.memory))").foregroundStyle(Theme.muted)
                    Spacer()
                    Hint(key: "⌘L", label: "Review")
                }
                .font(Theme.sans(12.5))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: Theme.radiusRow).fill(Theme.soft))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusRow).strokeBorder(Theme.borderStrong, lineWidth: 1))
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
    }

    private var lowDisk: Bool { stats.diskTotal > 0 && Double(stats.diskFree) / Double(stats.diskTotal) < 0.05 }
    private var pressure: String { stats.pressure >= 4 ? "critical" : (stats.pressure >= 2 ? "high" : "normal") }
    private var uptime: String {
        let d = Int(stats.uptime / 86400)
        return d >= 1 ? "\(d) \(d == 1 ? "day" : "days")" : Fmt.age(stats.uptime)
    }

    private func cell<V: View>(
        _ label: String,
        _ value: String,
        note: String,
        tint: Color? = nil,
        @ViewBuilder graphic: () -> V
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(Theme.sans(11.5)).foregroundStyle(Theme.muted)
                Spacer(minLength: 4)
                Text(value).font(Theme.sans(13.5, .semibold).monospacedDigit()).foregroundStyle(tint ?? Theme.text)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            graphic()
            Text(note).font(Theme.sans(11)).foregroundStyle(Theme.muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Count and memory of leftovers, and what the list means.
struct LeftoversHeader: View {
    let count: Int
    let memory: UInt64
    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            figure("\(count)", count == 1 ? "process" : "processes")
            figure(Fmt.memory(memory), "memory")
            Text(
                "Dev tools whose terminal, editor or agent session has closed. Nothing started them and nothing is using them."
            )
            .font(Theme.sans(12))
            .foregroundStyle(Theme.text2)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func figure(_ v: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(v).font(Theme.sans(22, .semibold).monospacedDigit()).foregroundStyle(Theme.text)
            Text(label).font(Theme.sans(11.5)).foregroundStyle(Theme.muted)
        }
    }
}

/// Free space and how much the listed folders hold.
struct StorageHeader: View {
    let free: Int64
    let total: Int64
    let listed: Int64

    var body: some View {
        let used = max(0, total - free - listed)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(Fmt.bytes(free)) free")
                    .font(Theme.sans(22, .semibold).monospacedDigit())
                    .foregroundStyle(lowDisk ? Theme.synNumber : Theme.text)
                Text("of \(Fmt.bytes(total))").font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                Spacer()
                if listed > 0 {
                    Text("\(Fmt.bytes(listed)) in the folders below").font(Theme.sans(12.5)).foregroundStyle(
                        Theme.text2
                    )
                }
            }
            GeometryReader { g in
                let w = g.size.width - 4
                let t = Double(max(1, total))
                HStack(spacing: 2) {
                    Rectangle().fill(Theme.borderStrong).frame(width: w * Double(used) / t)
                    Rectangle().fill(Theme.synNumber).frame(width: w * Double(listed) / t)
                    Rectangle().fill(Theme.synString).frame(width: max(2, w * Double(free) / t))
                }
                .clipShape(Capsule())
            }
            .frame(height: 7)
            HStack(spacing: 14) {
                legend(Theme.borderStrong, "Everything else")
                legend(Theme.synNumber, "Caches, SDKs, Downloads")
                legend(Theme.synString, "Free")
            }
            .font(Theme.sans(11.5))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var lowDisk: Bool { total > 0 && Double(free) / Double(total) < 0.05 }

    private func legend(_ c: Color, _ s: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text(s).foregroundStyle(Theme.text2)
        }
    }
}

/// CPU · Memory · Disk · Network in the processes header; Tab moves along.
struct SortTabs: View {
    let sort: ProcSort
    var body: some View {
        HStack(spacing: 2) {
            ForEach(ProcSort.allCases, id: \.self) { s in
                Text(s.rawValue)
                    .font(Theme.sans(12, s == sort ? .medium : .regular))
                    .foregroundStyle(s == sort ? Theme.text : Theme.text2)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(s == sort ? Theme.raised : .clear))
            }
        }
        .padding(2)
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border, lineWidth: 1))
    }
}
