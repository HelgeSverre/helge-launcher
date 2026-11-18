import AppKit
import Foundation
import Testing
@testable import HelgeLauncher

func executable(_ body: String) throws -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("exe-\(UUID().uuidString)")
    try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
}

@Suite struct ShellRunTests {
    @Test func largeStderrDoesNotStallStdout() async throws {
        let start = Date()
        let out = try await Shell.run("/bin/sh", ["-c", "head -c 300000 /dev/zero | tr '\\\\0' x >&2; echo done"], timeout: 5)
        #expect(String(decoding: out, as: UTF8.self) == "done\n")
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func backgroundedGrandchildDoesNotHoldTheResult() async throws {
        let start = Date()
        let out = try await Shell.run("/bin/sh", ["-c", "sleep 3 & echo hi"], timeout: 10)
        #expect(String(decoding: out, as: UTF8.self) == "hi\n")
        #expect(Date().timeIntervalSince(start) < 1.5)
    }

    @Test func timeoutReturnsPromptlyAndSaysSo() async throws {
        let start = Date()
        do {
            _ = try await Shell.run("/bin/sleep", ["5"], timeout: 0.5)
            Issue.record("expected a timeout")
        } catch {
            #expect(error.localizedDescription == "sleep timed out after 0.5s")
        }
        #expect(Date().timeIntervalSince(start) < 1.5)
    }

    @Test func cancellationTerminatesTheProcess() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("pid-\(UUID().uuidString)").path
        let script = try executable("echo $$ > \(pidFile)\nexec sleep 10\n")
        let task = Task { try await Shell.run(script, [], timeout: 30) }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidFile) { try await Task.sleep(nanoseconds: 20_000_000) }
        let pid = try #require(Int32(String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        task.cancel()
        _ = try? await task.value
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(kill(pid, 0) != 0)
    }

    @Test func nonZeroExitReportsStderr() async throws {
        await #expect(throws: Shell.Failure.self) { _ = try await Shell.run("/bin/sh", ["-c", "echo nope >&2; exit 3"]) }
    }
}

@Suite @MainActor struct OnePasswordTests {
    @Test func concurrentRefreshesShareOneOpRun() async throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("op-\(UUID().uuidString).log").path
        let op = try executable("""
        echo "$1 $2" >> \(log)
        case "$1" in
          item) sleep 0.3; echo '[{"id":"i1","title":"GitHub","category":"LOGIN","vault":{"id":"v","name":"Personal"}}]' ;;
          whoami) echo '{"account_uuid":"A"}' ;;
        esac
        """)
        let onePassword = OnePassword()
        onePassword.config.op = op
        async let a: Void = onePassword.refresh()
        async let b: Void = onePassword.refresh()
        _ = await (a, b)
        let calls = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n").filter { $0.hasPrefix("item") }
        #expect(calls.count == 1)
        #expect(onePassword.items.map(\.title) == ["GitHub"])
    }
}

extension PasteboardTests {
@Suite @MainActor struct SnippetSecretTests {
    @Test func secretsAreConcealedSkippedByHistoryAndCleared() async throws {
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        let history = ClipboardHistory()
        history.poll()
        let before = history.entries.count
        OnePassword.shared.config.clearAfter = 1

        Snippets.deliver(.init(text: "s3cret-\(UUID().uuidString)", isSecret: true), paste: false, target: nil)
        let types = NSPasteboard.general.types ?? []
        #expect(types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")))
        history.poll()
        #expect(history.entries.count == before)

        try await Task.sleep(nanoseconds: 1_300_000_000)
        #expect(NSPasteboard.general.string(forType: .string) == nil)
    }

    @Test func plainSnippetsAreOrdinaryCopies() {
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        Snippets.deliver(.init(text: "plain", isSecret: false), paste: false, target: nil)
        #expect(!(NSPasteboard.general.types ?? []).contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")))
        #expect(NSPasteboard.general.string(forType: .string) == "plain")
    }
}
}
