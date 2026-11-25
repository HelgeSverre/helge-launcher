import AppKit
import Calc
import SwiftUI

/// Headless entry points:
/// `--search <q> [--mode m] [--limit n]`, `--plugin <name> [--search q]`, `--expand <text>`, `--ai <question>`,
/// `--render <png> [--mode m] [--search q] [--light] [--actions]`, `--render-helper <png>`.
@MainActor
enum CLI {
    struct Arguments {
        let raw: [String]

        func value(_ name: String) -> String? {
            guard let i = raw.firstIndex(of: name), i + 1 < raw.count else { return nil }
            return raw[i + 1]
        }

        func has(_ flag: String) -> Bool { raw.contains(flag) }
    }

    static let commands = [
        "--search", "--ai", "--mode", "--plugin", "--expand", "--render", "--render-helper", "--calc", "--answer",
    ]

    static func handles(_ args: [String]) -> Bool { commands.contains(where: args.contains) }

    static func run(_ raw: [String]) async -> Int32 {
        let args = Arguments(raw: raw)
        if let out = args.value("--render-helper") {
            _ = NSApplication.shared
            PermissionHelper.shared.renderPreview(to: out)
            return 0
        }
        let loaded = ConfigLoader.load()
        if let err = loaded.error { print("config error: \(err)") }
        let cfg = loaded.config ?? Config()
        OnePassword.shared.config = cfg.onepassword

        if let out = args.value("--render") {
            _ = NSApplication.shared
            render(cfg, args, to: out)
            return 0
        }
        if let text = args.value("--expand") { return await expand(text) }
        if let q = args.value("--calc") { return calc(q, cfg) }
        if let name = args.value("--plugin") { return await plugin(name, cfg, query: args.value("--search") ?? "") }
        if let q = args.value("--ai") { return await ask(q, cfg) }
        return await search(cfg, args)
    }

    private static func mode(_ name: String?) -> Mode {
        switch name {
        case "emoji": return .emoji
        case "snippets": return .snippets
        case "clipboard": return .clipboard
        case "onepassword": return .onepassword
        case "ai": return .ai
        case "chats": return .chats
        case "stats": return .stats
        case "processes": return .processes
        case "ports": return .ports
        case "leftovers": return .leftovers
        case "storage": return .storage
        default: return .root
        }
    }

    /// Prints the answer, its reading and any other readings; exit 1 when there is no answer.
    private static func calc(_ q: String, _ cfg: Config) -> Int32 {
        switch Calculator.evaluate(q, CalcProvider.context(cfg.calculator, previous: nil)) {
        case .none:
            print("(not a calculation)")
            return 1
        case .error(let m):
            print("error: \(m)")
            return 1
        case .result(let r):
            print(r.primary.text + (r.primary.label.map { "  (\($0))" } ?? ""))
            print("  = \(r.interpretation)")
            for st in r.steps {
                print("    \(st.operation.padding(toLength: 44, withPad: " ", startingAt: 0)) \(st.result)")
            }
            for a in r.alternatives { print("  or \(a.text)" + (a.label.map { "  (\($0))" } ?? "")) }
            return 0
        }
    }

    private static func expand(_ text: String) async -> Int32 {
        guard let e = await Snippets.expand(text) else {
            print("error: could not expand")
            return 1
        }
        print(e.text)
        return 0
    }

    private static func plugin(_ name: String, _ cfg: Config, query: String) async -> Int32 {
        guard let p = cfg.plugin.first(where: { $0.name == name }) else {
            print("no plugin named \(name) in config")
            return 1
        }
        for it in await Plugins.query(p, query) {
            let subtitle = it.subtitle.isEmpty ? "" : "  — \(it.subtitle)"
            let accessory = it.accessory.isEmpty ? "" : "  [\(it.accessory)]"
            print(it.title + subtitle + accessory)
            for a in it.actions { print("    · \(a.title)\(a.detail.isEmpty ? "" : ": \(a.detail)")") }
        }
        return 0
    }

    private static func ask(_ q: String, _ cfg: Config) async -> Int32 {
        var ai = cfg.ai
        ai.enabled = true
        OpenCode.shared.apply(ai)
        defer { OpenCode.shared.stop() }
        do {
            let session = try await OpenCode.shared.createSession()
            var finished = false
            try await OpenCode.shared.prompt(session, text: q) { ev in
                switch ev {
                case .delta(let d): FileHandle.standardOutput.write(Data(d.utf8))
                case .toolInput(_, let d): FileHandle.standardError.write(Data("[tool \(d)]\n".utf8))
                case .thinking, .toolStarted, .toolEnded: break
                case .done: finished = true
                case .failed(let e):
                    print("\nfailed: \(e)")
                    finished = true
                }
            }
            let deadline = Date().addingTimeInterval(120)
            while !finished && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            print("")
            return finished ? 0 : 1
        } catch {
            print("ai error: \(error.localizedDescription)")
            return 1
        }
    }

    private static func search(_ cfg: Config, _ args: Arguments) async -> Int32 {
        let l = Launcher()
        l.apply(cfg)
        AppIndex.shared.scan()
        l.mode = mode(args.value("--mode"))
        if l.mode == .onepassword { await OnePassword.shared.refresh() }
        l.stopSampling()
        applySystemFlags(l, args)
        _ = await SystemSampler.shared.sample()
        try? await Task.sleep(nanoseconds: 700_000_000)
        let started = Date()
        l.snapshot = await SystemSampler.shared.sample(network: l.procSort == .network)
        if args.has("--timing") {
            print(String(format: "sample took %.0f ms", Date().timeIntervalSince(started) * 1000))
        }
        l.query = args.value("--search") ?? ""
        let items = l.computeItems()
        print("\(items.count) results (apps indexed: \(AppIndex.shared.apps.count))")
        for it in items.prefix(Int(args.value("--limit") ?? "15") ?? 15) {
            let subtitle = l.mode == .snippets ? "" : it.subtitle
            print(
                String(
                    format: "%7.2f  %@  %@  %@  %@",
                    it.score,
                    it.title,
                    subtitle,
                    it.accessory,
                    it.system.map { "\($0)" } ?? ""
                )
            )
        }
        return 0
    }

    /// --sort cpu|memory|disk|network (and --open-group <title> in renders).
    private static func applySystemFlags(_ l: Launcher, _ args: Arguments) {
        if let s = args.value("--sort"), let sort = ProcSort.allCases.first(where: { $0.rawValue.lowercased() == s }) {
            l.procSort = sort
        }
    }

    /// Two samples (CPU needs a difference) without the 2-second loop; blocks the caller.
    private static func sampleNow(_ l: Launcher) {
        l.stopSampling()
        let sem = DispatchSemaphore(value: 0)
        let network = l.procSort == .network
        var snap: SystemSnapshot?
        Task.detached {
            _ = await SystemSampler.shared.sample(network: network)
            try? await Task.sleep(nanoseconds: 700_000_000)
            snap = await SystemSampler.shared.sample(network: network)
            sem.signal()
        }
        sem.wait()
        l.snapshot = snap
    }

    private static func render(_ cfg: Config, _ args: Arguments, to path: String) {
        let l = Launcher()
        l.apply(cfg)
        AppIndex.shared.scan()
        l.mode = mode(args.value("--mode"))
        applySystemFlags(l, args)
        sampleNow(l)
        if l.mode == .storage && args.has("--measure") {
            StorageScanner.shared.refresh(maxAge: 0)
            let deadline = Date().addingTimeInterval(300)
            while !StorageScanner.shared.measuring.isEmpty && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            }
        }
        if l.mode == .ai {
            var turns = sampleTurns
            if args.has("--busy") { turns.append(busyTurn) }
            // --answer FILE: the last answer's Markdown, to preview rendering.
            if let f = args.value("--answer"), let md = try? String(contentsOfFile: f, encoding: .utf8) {
                turns[turns.count - 1].answer = md
            }
            l.conversation = Conversation(backend: OpenCode.shared, turns: turns)
            if args.has("--selected") { l.selectedTurn = turns.last?.id }
            if args.has("--menu") {
                l.chatMenu = args.value("--menu") == "chat" ? .chat : .message(turns[turns.count - 1].id)
            }
        }
        if args.has("--sample-chats") {
            for (i, t) in (sampleTurns + [busyTurn]).enumerated() {
                var t = t
                t.done = true
                t.finished = Date().addingTimeInterval(Double(-i) * 30_000)
                let chat = SavedChat(
                    id: UUID(),
                    title: Conversation.title(t.question),
                    created: t.started,
                    updated: t.finished!,
                    model: cfg.ai.model,
                    turns: [t]
                )
                ChatStore.shared.save(chat)
            }
        }
        l.query = args.value("--search") ?? ""
        if l.mode != .ai { l.setItems(l.computeItems(), keepSelection: false) }
        if let g = args.value("--open-group"), let i = l.items.firstIndex(where: { $0.title == g }) {
            l.selected = i
            _ = l.expandSelected()
        }
        if args.has("--steps") { l.showSteps = true }
        if args.has("--actions") {
            l.selected = 0
            l.showActions = true
        }
        let host = NSHostingView(rootView: LauncherView().environmentObject(l).framedPanel())
        host.appearance = NSAppearance(named: args.has("--light") ? .aqua : .darkAqua)
        host.frame = NSRect(origin: .zero, size: Theme.panelSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        writePNG(host, to: path)
    }

    private static var sampleTurns: [ChatTurn] {
        var a = ChatTurn(
            question: "what's UNIT_MULT in the norges bank csv?",
            answer:
                "`UNIT_MULT` is a power of ten: `2` means the rate is quoted per 100 units, so SEK, DKK and JPY need dividing by 100.",
            done: true
        )
        a.started = Date().addingTimeInterval(-90)
        var b = ChatTurn(
            question: "How do I parse that CSV in Swift and scale by UNIT_MULT?",
            answer: #"""
                Split on newlines and `;`, then read four columns:

                | Field | Column | Example |
                |---|---:|---|
                | BASE_CUR | 3 | SEK |
                | UNIT_MULT | 11 | 2 |
                | OBS_VALUE | 16 | 95.59 |

                ```swift
                for line in csv.split(whereSeparator: \.isNewline).dropFirst() {
                    let f = line.split(separator: ";").map(String.init)
                    guard let mult = Int(f[10]), let v = Decimal(string: f[15]) else { continue }
                    rates[f[2]] = v / pow(10, mult)  // NOK per 1 unit
                }
                ```

                > [!WARNING]
                > Missing the multiplier is a **100× error**.
                """#,
            done: true
        )
        b.started = Date().addingTimeInterval(-40)
        b.finished = Date().addingTimeInterval(-33)
        b.activities = [
            ChatActivity(
                id: "1",
                tool: "websearch",
                detail: "norges bank csv unit_mult",
                started: b.started,
                ended: b.started.addingTimeInterval(1.2),
                state: .done,
                resultCount: 4
            ),
            ChatActivity(
                id: "2",
                tool: "webfetch",
                detail: "https://www.norges-bank.no/en/topics/Statistics/exchange_rates/",
                started: b.started.addingTimeInterval(1.3),
                ended: b.started.addingTimeInterval(3.1),
                state: .done
            ),
        ]
        return [a, b]
    }

    private static var busyTurn: ChatTurn {
        var t = ChatTurn(question: "What's the USD/NOK fixing today, and how has it moved this month?")
        t.started = Date().addingTimeInterval(-4.8)
        t.answer = "The fixing on Friday 20 November was **9,7525 NOK** per dollar. Over November the dollar has"
        t.activities = [
            ChatActivity(
                id: "a",
                tool: "websearch",
                detail: "norges bank usd nok fixing",
                started: t.started,
                ended: t.started.addingTimeInterval(1),
                state: .done,
                resultCount: 4
            ),
            ChatActivity(
                id: "b",
                tool: "webfetch",
                detail: "https://www.norges-bank.no/en/topics/Statistics/exchange_rates/",
                started: t.started.addingTimeInterval(1.1),
                ended: t.started.addingTimeInterval(2.3),
                state: .done
            ),
            ChatActivity(
                id: "c",
                tool: "webfetch",
                detail: "https://data.norges-bank.no/api/data/EXR/B.USD.NOK.SP",
                started: t.started.addingTimeInterval(4.2),
                state: .running
            ),
        ]
        return t
    }

    static func writePNG(_ view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
