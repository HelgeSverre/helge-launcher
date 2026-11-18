import Foundation
import Testing
@testable import HelgeLauncher

@Suite struct SnippetPlaceholders {
    // 2026-11-18 14:05:09 UTC; formatted in the test process's time zone like the app does.
    let now = Date(timeIntervalSince1970: 1_795_010_709)
    func local(_ f: String) -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = f
        return df.string(from: now)
    }
    func expand(_ s: String) -> String { Snippets.placeholders(s, now: now, clipboard: { "CLIP" }) }

    @Test func dateAndTime() {
        #expect(expand("{date}") == local("yyyy-MM-dd"))
        #expect(expand("{time}") == local("HH:mm"))
        #expect(expand("{datetime}") == local("yyyy-MM-dd HH:mm"))
        #expect(expand("{weekday}") == local("EEEE"))
        #expect(expand("{date:dd.MM.yyyy}") == local("dd.MM.yyyy"))
        #expect(expand("{timestamp}") == "1795010709")
    }

    @Test func iso() {
        #expect(expand("{iso}") == ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withInternetDateTime]))
    }

    @Test func clipboardAndUUID() {
        #expect(expand("Yesterday: {clipboard}") == "Yesterday: CLIP")
        let u = expand("{uuid}")
        #expect(UUID(uuidString: u) != nil && u == u.lowercased())
        #expect(expand("{uuid}") != u)
    }

    @Test func unknownAndPlainTextUntouched() {
        #expect(expand("{nope} {DATE} {date") == "{nope} {DATE} {date")
        #expect(expand("no placeholders") == "no placeholders")
        #expect(expand("a {date} b {time} c").hasPrefix("a " + local("yyyy-MM-dd") + " b "))
    }
}

@Suite struct Matching {
    @Test func fuzzyPrefersPrefixAndWordStarts() {
        let tp = Fuzzy.score("tp", "TablePlus")!
        let cp = Fuzzy.score("tp", "ChatGPT")!
        #expect(tp > cp)
        #expect(Fuzzy.score("xyz", "Slack") == nil)
        #expect(Fuzzy.score("sl", "Slack")! > Fuzzy.score("sl", "Google Slides")!)
    }

    @Test func hotkeyParsing() {
        #expect(Hotkeys.parse("cmd+space")! == (49, 256))
        #expect(Hotkeys.parse("f12")!.key == 111)
        #expect(Hotkeys.parse("hyper+k")!.mods == 256 | 512 | 2048 | 4096)
        #expect(Hotkeys.parse("cmd+nope") == nil)
    }
}

@Suite struct PluginProtocol {
    @Test func decodesAllFields() throws {
        let json = #"{"items":[{"id":"1","title":"T","subtitle":"S","icon":"star","accessory":"A","actions":[{"title":"Open","open":"https://x"},{"title":"Copy","copy":"c"}]},{"title":"Minimal"}]}"#
        let out = try JSONDecoder().decode(Plugins.Output.self, from: Data(json.utf8))
        #expect(out.items.count == 2)
        #expect(out.items[0].actions?.count == 2)
        #expect(out.items[1].actions == nil)
        #expect(Plugins.action(out.items[0].actions![0]).detail == "open https://x")
    }

    @Test func iconKinds() {
        if case .symbol("star") = Plugins.icon("star") {} else { Issue.record("symbol") }
        if case .emoji("🚀") = Plugins.icon("🚀") {} else { Issue.record("emoji") }
        if case .file = Plugins.icon("~/x.png") {} else { Issue.record("file") }
    }
}

@Suite struct ConfigParsing {
    @Test func parsesSampleConfig() throws {
        let toml = """
        hotkey = "alt+space"
        [ai]
        model = "opencode-go/deepseek-v4.1-flash"
        [[snippet]]
        name = "a"
        text = "b"
        keyword = "k"
        [[plugin]]
        name = "Calc"
        exec = "plugins/calc.py"
        prefix = "="
        [[plugin]]
        name = "Units"
        exec = ["sema", "--no-llm", "plugins/units.sema", "--"]
        env = { NOTES_DIR = "~/Notes" }
        """
        let c = try ConfigLoader.parse(text: toml)
        #expect(c.hotkey == "alt+space")
        #expect(c.ai.providerID == "opencode-go" && c.ai.modelID == "deepseek-v4.1-flash")
        #expect(c.snippet.first?.keyword == "k")
        #expect(c.plugin.first?.prefix == "=")
        #expect(c.plugin.first?.exec == ["plugins/calc.py"])
        #expect(c.plugin.last?.exec == ["sema", "--no-llm", "plugins/units.sema", "--"])
        #expect(c.plugin.last?.env == ["NOTES_DIR": "~/Notes"])
        #expect(c.clipboard.maxItems == 500)
    }
}

@Suite struct PluginPrefix {
    @MainActor @Test func prefixJumpsIntoPlugin() {
        let l = Launcher()
        l.config.plugin = [PluginConfig(name: "Calc", exec: ["/usr/bin/true"], prefix: "="),
                           PluginConfig(name: "Processes", exec: ["/usr/bin/true"], prefix: "ps")]
        l.query = "= 2+2"
        #expect(l.mode == .plugin("Calc"))
        #expect(l.query == "2+2")
        l.mode = .root
        l.query = ""
        l.query = "psst"            // no space after the prefix: ordinary search
        #expect(l.mode == .root)
        l.query = "ps "             // prefix + space, empty rest
        #expect(l.mode == .plugin("Processes"))
        #expect(l.query == "")      // the field clears; the plugin runs with an empty query
    }
}

@Suite struct PluginRuntime {
    /// Runs a real plugin process: query as last argument, $HL_QUERY, configured env (with ~), cwd = config dir.
    @Test func passesQueryEnvAndArgs() async throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("hl-echo-\(UUID().uuidString).sh")
        try """
        #!/bin/sh
        printf '{"items":[{"title":"%s|%s|%s|%s"}]}' "$1" "$HL_QUERY" "$GREETING" "$WHERE"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }

        let p = PluginConfig(name: "Echo", exec: [script.path], env: ["GREETING": "hei", "WHERE": "~/x"])
        let items = await Plugins.query(p, "a b")
        #expect(items.first?.title == "a b|a b|hei|\(NSHomeDirectory())/x", "\(items.first?.subtitle ?? "")")
    }

    @Test func badOutputBecomesAnErrorItem() async {
        let p = PluginConfig(name: "Bad", exec: ["/bin/echo"])   // prints the query, not JSON
        let items = await Plugins.query(p, "not json")
        #expect(items.first?.title == "Bad failed")
    }

    @MainActor @Test func runActionExecutes() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("hl-run-\(UUID().uuidString)")
        let action = Plugins.action(Plugins.PAction(title: "Run", open: nil, copy: nil, paste: nil, run: "touch '\(marker.path)'"))
        _ = action.run()
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: marker.path) { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        try? FileManager.default.removeItem(at: marker)
    }
}
