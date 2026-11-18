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
        try await Task.sleep(nanoseconds: 900_000_000)
        #expect(l.items.map(\.title) == ["STALE"])
    }
}
