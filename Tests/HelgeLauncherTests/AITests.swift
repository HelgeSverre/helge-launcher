import Foundation
import Testing

@testable import HelgeLauncher

extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}

/// Backend whose session creation and events are driven by the test.
@MainActor
final class FakeAI: AIBackend {
    var sessionsCreated = 0
    var prompts: [(session: AISession, text: String)] = []
    var released: [AISession] = []
    var handlers: [String: @MainActor (AIEvent) -> Void] = [:]
    var pendingCreate: CheckedContinuation<AISession, Error>?
    var holdCreate = false
    var loseNextPrompt = false

    func createSession() async throws -> AISession {
        sessionsCreated += 1
        let s = AISession(id: "s\(sessionsCreated)", server: 1)
        if holdCreate { return try await withCheckedThrowingContinuation { pendingCreate = $0 } }
        return s
    }

    func prompt(_ session: AISession, text: String, onEvent: @escaping @MainActor (AIEvent) -> Void) async throws {
        if loseNextPrompt {
            loseNextPrompt = false
            throw AIError.sessionLost
        }
        prompts.append((session, text))
        handlers[session.id] = onEvent
    }

    func interrupt(_ session: AISession) async {}
    func release(_ session: AISession) {
        released.append(session)
        handlers[session.id] = nil
    }

    func emit(_ sid: String, _ e: AIEvent) { handlers[sid]?(e) }
}

@MainActor
func settle() async { for _ in 0..<20 { await Task.yield() } }

@Suite @MainActor struct ConversationTests {
    @Test func secondQuestionWaitsForTheFirstAnswer() async {
        let ai = FakeAI()
        let c = Conversation(backend: ai)
        #expect(c.send("Q1"))
        await settle()
        ai.emit("s1", .delta("one"))
        #expect(!c.send("Q2"))  // still streaming
        ai.emit("s1", .delta(" two"))
        ai.emit("s1", .done)
        #expect(c.turns.count == 1 && c.turns[0].answer == "one two" && c.turns[0].done)
        #expect(c.send("Q2"))
        await settle()
        ai.emit("s1", .delta("three"))
        #expect(c.turns[1].answer == "three")
        #expect(c.turns[0].answer == "one two")
        #expect(ai.sessionsCreated == 1)
    }

    @Test func resetDropsAPendingSessionAndItsEvents() async {
        let ai = FakeAI()
        let c = Conversation(backend: ai)
        ai.holdCreate = true
        c.send("old")
        await settle()
        c.reset()
        ai.holdCreate = false
        c.send("new")
        await settle()
        ai.pendingCreate?.resume(returning: AISession(id: "s1", server: 1))  // the old creation completes late
        await settle()
        #expect(ai.prompts.map(\.text) == ["new"])
        ai.emit("s1", .delta("stale"))
        ai.emit("s2", .delta("fresh"))
        #expect(c.turns.count == 1 && c.turns[0].question == "new" && c.turns[0].answer == "fresh")
    }

    @Test func resetReleasesTheSessionSoLateEventsAreIgnored() async {
        let ai = FakeAI()
        let c = Conversation(backend: ai)
        c.send("Q1")
        await settle()
        let handler = ai.handlers["s1"]
        c.reset()
        #expect(ai.released.map(\.id) == ["s1"])
        handler?(.delta("late"))
        #expect(c.turns.isEmpty)
    }

    @Test func lostSessionIsRecreatedOnce() async {
        let ai = FakeAI()
        let c = Conversation(backend: ai)
        c.send("Q1")
        await settle()
        ai.emit("s1", .done)
        ai.loseNextPrompt = true
        c.send("Q2")
        await settle()
        #expect(ai.sessionsCreated == 2)
        #expect(ai.prompts.last?.session.id == "s2")
    }

    @Test func failureEndsTheTurn() async {
        let ai = FakeAI()
        let c = Conversation(backend: ai)
        c.send("Q1")
        await settle()
        ai.emit("s1", .failed("boom"))
        #expect(c.turns[0].done && c.turns[0].status == "Failed: boom")
        ai.emit("s1", .delta("after"))
        #expect(c.turns[0].answer.isEmpty)
        #expect(!c.isBusy)
    }
}

/// Fake `opencode` executables: the server lifecycle runs real child processes.
@Suite(.serialized) @MainActor struct OpenCodeLifecycleTests {
    func script(_ body: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-opencode-\(UUID().uuidString)")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func server(_ body: String, timeout: TimeInterval = 5) throws -> OpenCode {
        let oc = OpenCode()
        oc.startTimeout = timeout
        var cfg = AIConfig()
        cfg.opencode = try script(body)
        cfg.enabled = false
        oc.apply(cfg)
        cfg.enabled = true
        oc.apply(cfg)
        return oc
    }

    /// Prints a URL, then waits for stdin to close, like `opencode serve --stdio`.
    let healthy = #"echo '{"url":"http://127.0.0.1:9"}'; cat > /dev/null; echo exited >&2"#

    @Test func concurrentStartsShareOneServer() async throws {
        let oc = try server(healthy)
        async let a = oc.ensureStarted()
        async let b = oc.ensureStarted()
        let (x, y) = try await (a, b)
        #expect(x == y)
        oc.stop()
    }

    @Test func deadServerIsReplacedOnNextUse() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("pid-\(UUID().uuidString)").path
        let oc = try server(#"echo $$ > "# + pidFile + #"; echo '{"url":"http://127.0.0.1:9"}'; cat > /dev/null"#)
        let first = try await oc.ensureStarted()
        let pid = try #require(
            Int32(String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
        )
        kill(pid, SIGKILL)
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            if (try? await oc.ensureStarted()) != first { break }
        }
        let second = try await oc.ensureStarted()
        #expect(second != first)
        oc.stop()
    }

    @Test func serverThatNeverReportsAURLTimesOut() async throws {
        let oc = try server("exec sleep 30", timeout: 0.5)
        let start = Date()
        await #expect(throws: AIError.self) { _ = try await oc.ensureStarted() }
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func stopClosesStdinSoTheChildExits() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("exit-\(UUID().uuidString)").path
        let oc = try server(#"echo '{"url":"http://127.0.0.1:9"}'; cat > /dev/null; touch "# + marker)
        _ = try await oc.ensureStarted()
        oc.stop()
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(FileManager.default.fileExists(atPath: marker))
    }

    @Test func serverThatExitsRightAfterItsURLIsNotKept() async throws {
        let oc = try server(#"echo '{"url":"http://127.0.0.1:9"}'; exit 0"#)
        let first = try? await oc.ensureStarted()
        try await Task.sleep(nanoseconds: 300_000_000)
        let second = try? await oc.ensureStarted()
        #expect(first == nil || second != first)
        oc.stop()
    }

    @Test func callersJoiningAStartSeeAnInstalledServer() async throws {
        let oc = try server(healthy)
        async let a = Result(catching: { try await oc.createSession() })
        async let b = Result(catching: { try await oc.createSession() })
        for r in await [a, b] {
            if case .failure(let e) = r { #expect(e as? AIError != .sessionLost) }
        }
        oc.stop()
    }

    @Test func stopDuringStartKillsTheChild() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("start-\(UUID().uuidString)").path
        let oc = try server(#"echo $$ > "# + pidFile + #"; exec sleep 5"#)
        Task { _ = try? await oc.ensureStarted() }
        var written: Int32?
        for _ in 0..<250 where written == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
            written = (try? String(contentsOfFile: pidFile, encoding: .utf8))
                .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let pid = try #require(written)
        oc.stop()
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(kill(pid, 0) != 0)
    }

    @Test func stopDuringStartFailsEveryWaiter() async throws {
        let oc = try server(#"sleep 0.3; echo '{"url":"http://127.0.0.1:9"}'; cat > /dev/null"#)
        async let a = Result(catching: { try await oc.ensureStarted() })
        async let b = Result(catching: { try await oc.ensureStarted() })
        try await Task.sleep(nanoseconds: 50_000_000)
        oc.stop()
        for r in await [a, b] {
            if case .success = r { Issue.record("a waiter got a server that was stopped") }
        }
    }

    @Test func disablingStopsAndRefusesToStart() async throws {
        let oc = try server(healthy)
        _ = try await oc.ensureStarted()
        var cfg = oc.config
        cfg.enabled = false
        oc.apply(cfg)
        await #expect(throws: AIError.disabled) { _ = try await oc.ensureStarted() }
    }
}
