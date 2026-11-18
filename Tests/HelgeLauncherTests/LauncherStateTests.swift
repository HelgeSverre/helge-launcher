import Foundation
import Testing
@testable import HelgeLauncher

@MainActor
func item(_ id: String, log: Box<[String]>? = nil) -> Item {
    Item(id: id, title: id, actions: [
        Action(title: "Primary") { log?.value.append("\(id).primary"); return true },
        Action(title: "Secondary") { log?.value.append("\(id).secondary"); return true },
    ])
}

final class Box<T> { var value: T; init(_ v: T) { value = v } }

@Suite @MainActor struct LauncherSelectionTests {
    @Test func keepSelectionFollowsTheItemById() {
        let l = Launcher(ai: FakeAI())
        l.setItems([item("a"), item("b"), item("c")], keepSelection: false)
        l.selected = 2
        l.setItems([item("c"), item("a"), item("b")], keepSelection: true)
        #expect(l.current?.id == "c")
        l.setItems([item("x"), item("y")], keepSelection: false)
        #expect(l.selected == 0)
    }

    @Test func actionsMenuClosesOnlyWhenTheSelectedItemChanges() {
        let l = Launcher(ai: FakeAI())
        l.setItems([item("a"), item("b")], keepSelection: false)
        l.showActions = true
        l.setItems([item("a"), item("c")], keepSelection: true)
        #expect(l.showActions)
        l.setItems([item("z")], keepSelection: true)
        #expect(!l.showActions)
    }

    @Test func clickRunsTheClickedRowsPrimaryActionEvenWithTheMenuOpen() {
        let log = Box<[String]>([])
        let l = Launcher(ai: FakeAI())
        l.setItems([item("a", log: log), item("b", log: log)], keepSelection: false)
        l.showActions = true
        l.actionIndex = 1
        l.click(1)
        #expect(log.value == ["b.primary"])
        #expect(!l.showActions)
    }

    @Test func duplicateIdsAreMadeUnique() {
        let l = Launcher(ai: FakeAI())
        l.setItems([item("a"), item("a"), item("b"), item("a")], keepSelection: false)
        #expect(l.items.map(\.id) == ["a", "a#1", "b", "a#2"])
        l.setItems([item("a#1"), item("a"), item("a")], keepSelection: false)
        #expect(l.items.map(\.id) == ["a#1", "a", "a#2"])
    }

    @Test func askingWhileTheAIIsBusyKeepsTheQuestion() async {
        let ai = FakeAI()
        let l = Launcher(ai: ai)
        l.config.ai.enabled = true
        l.askAI("first")
        await settle()
        l.mode = .root
        l.query = "second"
        l.askAI("second")
        #expect(l.mode == .root && l.query == "second")
    }

    @Test func busyAskFromRootDoesNotRewriteTheQuery() async {
        let ai = FakeAI()
        let l = Launcher(ai: ai)
        l.config.ai.enabled = true
        l.config.plugin = [PluginConfig(name: "Units", exec: "/usr/bin/true", prefix: "u")]
        l.askAI("first")
        await settle()
        l.mode = .root
        l.query = " u 10 km"
        l.tab()
        #expect(l.mode == .root && l.query == " u 10 km")
    }

    @Test func busyAskFromAURLLandsInTheChat() async {
        let l = Launcher(ai: FakeAI())
        l.config.ai.enabled = true
        l.askAI("first")
        await settle()
        l.back()
        l.show()
        l.askAI("second")
        #expect(l.mode == .ai && l.query == "second")
    }

    @Test func busyAskFromAURLKeepsAnUnsentDraft() async {
        let l = Launcher(ai: FakeAI())
        l.config.ai.enabled = true
        l.askAI("first")
        await settle()
        l.query = "my draft"
        l.askAI("from shortcut")
        #expect(l.mode == .ai && l.query == "my draft")
    }

    @Test func idleAskFromAURLSendsAndKeepsTheDraft() async {
        let ai = FakeAI()
        let l = Launcher(ai: ai)
        l.config.ai.enabled = true
        l.askAI("first")
        await settle()
        ai.emit("s1", .done)
        l.query = "my draft"
        l.askAI("from shortcut")
        await settle()
        #expect(l.query == "my draft")
        #expect(ai.prompts.map(\.text) == ["first", "from shortcut"])
    }

    @Test func emptyQuestionOpensTheChatWithoutSending() async {
        let ai = FakeAI()
        let l = Launcher(ai: ai)
        l.config.ai.enabled = true
        l.askAI("  ")
        l.askAI("\n")
        await settle()
        #expect(l.mode == .ai && l.conversation.turns.isEmpty && ai.prompts.isEmpty)
    }

    @Test func openingTheChatKeepsADraft() {
        let l = Launcher(ai: FakeAI())
        l.config.ai.enabled = true
        l.openAIChat()
        l.query = "draft"
        l.openAIChat()
        #expect(l.query == "draft")
    }

    @Test func aiChatRespectsEnabled() {
        let l = Launcher(ai: FakeAI())
        l.config.ai.enabled = false
        l.openAIChat()
        #expect(l.mode == .root)
        l.config.ai.enabled = true
        l.openAIChat()
        #expect(l.mode == .ai)
    }

    @Test func tabWithTheActionsMenuOpenClosesIt() {
        let l = Launcher(ai: FakeAI())
        l.config.ai.enabled = true
        l.setItems([item("a")], keepSelection: false)
        l.query = "hello"
        l.showActions = true
        l.tab()
        #expect(l.mode == .ai && !l.showActions)
    }

    @Test func showWithAQueryLeavesTheAIChat() {
        let l = Launcher(ai: FakeAI())
        l.config.ai.enabled = true
        l.mode = .ai
        l.show(query: "cap")
        #expect(l.mode == .root && l.query == "cap")
        l.mode = .ai
        l.show()
        #expect(l.mode == .ai)
    }

    @Test func enteringAPluginRecordsItsListId() {
        let l = Launcher(ai: FakeAI())
        let name = "P\(UUID().uuidString.prefix(6))"
        l.config.plugin = [PluginConfig(name: name, exec: "/usr/bin/true", prefix: "zz")]
        l.query = "zz x"
        #expect(l.mode == .plugin(name))
        #expect(History.shared.boost(Mode.plugin(name).itemID) > 0)
        #expect(Plugins.entry(l.config.plugin[0]).id == Mode.plugin(name).itemID)
    }
}

@Suite(.serialized) @MainActor struct PluginStalenessTests {
    func slowPlugin() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("slow-\(UUID().uuidString).sh")
        try "#!/bin/sh\nsleep 0.4\necho '{\"items\":[{\"title\":\"STALE\"}]}'\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    @Test func leavingThePluginDropsItsPendingResults() async throws {
        let l = Launcher(ai: FakeAI())
        l.config.plugin = [PluginConfig(name: "Slow", exec: try slowPlugin())]
        l.enter(.plugin("Slow"))
        try await Task.sleep(nanoseconds: 200_000_000)   // past the debounce: the process is running
        l.back()
        #expect(l.mode == .root)
        let rootIDs = l.items.map(\.id)
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(l.mode == .root)
        #expect(l.items.map(\.id) == rootIDs)
        #expect(!l.items.contains { $0.title == "STALE" })
    }

    @Test func resultsArriveWhileStillInThePlugin() async throws {
        let l = Launcher(ai: FakeAI())
        l.config.plugin = [PluginConfig(name: "Slow", exec: try slowPlugin())]
        l.enter(.plugin("Slow"))
        for _ in 0..<100 where l.items.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(l.items.map(\.title) == ["STALE"])
    }
}
