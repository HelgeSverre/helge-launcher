import AppKit
import Foundation
import Testing
@testable import HelgeLauncher

@Suite struct ConfigLoadTests {
    func dir(_ files: [String: String]) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        for (name, body) in files { try body.write(to: d.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        return d
    }

    @Test func missingIncludeIsEmptyAndWatched() throws {
        let d = try dir(["config.toml": #"include = ["extra.toml"]"#])
        let loaded = ConfigLoader.load(from: d)
        #expect(loaded.error == nil && loaded.config?.snippet.isEmpty == true)
        #expect(loaded.warnings == ["include extra.toml not found"])
        #expect(loaded.stamps[d.appendingPathComponent("extra.toml").path] == .distantPast)
        #expect(loaded.stamps.keys.map { ($0 as NSString).lastPathComponent }.sorted() == ["config.toml", "extra.toml"])

        try #"[[snippet]]\#nname = "a"\#ntext = "b""#.write(to: d.appendingPathComponent("extra.toml"), atomically: true, encoding: .utf8)
        let fixed = ConfigLoader.load(from: d)
        #expect(fixed.error == nil && fixed.config?.snippet.map(\.name) == ["a"])
    }

    @Test func brokenIncludeReportsTheFile() throws {
        let d = try dir(["config.toml": #"include = ["extra.toml"]"#, "extra.toml": "[[snippet]\n"])
        let loaded = ConfigLoader.load(from: d)
        #expect(loaded.error?.contains("extra.toml") == true)
        #expect(loaded.stamps.count == 2)
    }

    @Test func missingConfigIsCreatedWithDefaults() throws {
        let d = try dir([:])
        let loaded = ConfigLoader.load(from: d)
        #expect(loaded.error == nil && loaded.warnings.isEmpty)
        #expect(loaded.config?.hotkey == "cmd+space")
        #expect(FileManager.default.fileExists(atPath: d.appendingPathComponent("config.toml").path))
        #expect(FileManager.default.fileExists(atPath: d.appendingPathComponent("snippets.toml").path))
    }
}

/// Tests that share the process's test pasteboard and clipboard files run in here, one at a time.
@Suite(.serialized) @MainActor struct PasteboardTests {}

extension PasteboardTests {
@Suite @MainActor struct ClipboardImageTests {
    func png(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 4, height: 4), flipped: false) { r in color.setFill(); r.fill(); return true }
    }

    func copyImage(_ image: NSImage) {
        Pasteboard.board.clearContents()
        Pasteboard.board.writeObjects([image])
    }

    @Test func sameImageIsOneEntryAndDeleteRemovesTheFile() throws {
        let h = ClipboardHistory()
        let dir = Paths.supportDir.appendingPathComponent("clipboard-images")
        let filesBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        let entriesBefore = h.entries.count
        let red = png(.red)
        copyImage(red); h.poll()
        copyImage(red); h.poll()
        let newFiles = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).subtracting(filesBefore)
        #expect(newFiles.count == 1)
        #expect(h.entries.count == entriesBefore + 1)

        let entry = try #require(h.entries.first)
        #expect(entry.kind == .image && newFiles.contains(entry.text))
        h.delete(entry.id)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(entry.text).path))
    }

    @Test func restoringAMissingImageDropsItAndKeepsTheClipboard() throws {
        let h = ClipboardHistory()
        copyImage(png(.blue)); h.poll()
        let entry = try #require(h.entries.first)
        try FileManager.default.removeItem(at: Paths.supportDir.appendingPathComponent("clipboard-images").appendingPathComponent(entry.text))
        Pasteboard.board.clearContents()
        Pasteboard.board.setString("keep me", forType: .string)
        #expect(h.restore(entry) == false)
        #expect(Pasteboard.board.string(forType: .string) == "keep me")
        #expect(!h.entries.contains { $0.id == entry.id })
    }

    /// Snapshot of the test data directory's clipboard files, restored on exit.
    @MainActor
    final class ClipboardState {
        let fm = FileManager.default
        let json = Paths.supportDir.appendingPathComponent("clipboard.json")
        let images = Paths.supportDir.appendingPathComponent("clipboard-images")
        let backup = FileManager.default.temporaryDirectory.appendingPathComponent("clip-backup-\(UUID().uuidString)")

        init() throws {
            try fm.createDirectory(at: backup, withIntermediateDirectories: true)
            if fm.fileExists(atPath: json.path) { try fm.copyItem(at: json, to: backup.appendingPathComponent("clipboard.json")) }
            if fm.fileExists(atPath: images.path) { try fm.copyItem(at: images, to: backup.appendingPathComponent("images")) }
        }

        func restore() {
            try? fm.removeItem(at: json)
            for name in (try? fm.contentsOfDirectory(atPath: Paths.supportDir.path)) ?? [] where name.hasPrefix("clipboard.json.") {
                try? fm.removeItem(at: Paths.supportDir.appendingPathComponent(name))
            }
            try? fm.removeItem(at: images)
            try? fm.moveItem(at: backup.appendingPathComponent("clipboard.json"), to: json)
            if (try? fm.moveItem(at: backup.appendingPathComponent("images"), to: images)) == nil {
                try? fm.createDirectory(at: images, withIntermediateDirectories: true)
            }
            try? fm.removeItem(at: backup)
        }

        var setAsideFiles: [String] {
            ((try? fm.contentsOfDirectory(atPath: Paths.supportDir.path)) ?? []).filter { $0.hasPrefix("clipboard.json.corrupt") }
        }
    }

    @Test func corruptHistoryKeepsItsImages() throws {
        let state = try ClipboardState()
        defer { state.restore() }
        let fm = FileManager.default
        let json = state.json
        let image = state.images.appendingPathComponent("keep-\(UUID().uuidString).png")
        try fm.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("png".utf8).write(to: image)
        try Data("[{\"id\":".utf8).write(to: json)
        let h = ClipboardHistory()
        h.removeUnreferencedImages()
        #expect(fm.fileExists(atPath: image.path))
        #expect(state.setAsideFiles.count == 1)
        #expect(h.entries.isEmpty)

        Pasteboard.board.clearContents()
        Pasteboard.board.setString("after-\(UUID().uuidString)", forType: .string)
        h.poll()
        ClipboardHistory().removeUnreferencedImages()
        #expect(fm.fileExists(atPath: image.path))

        for name in state.setAsideFiles { try fm.removeItem(at: Paths.supportDir.appendingPathComponent(name)) }
        ClipboardHistory().removeUnreferencedImages()
        #expect(!fm.fileExists(atPath: image.path))
    }

    @Test func deletingAnEntryKeepsImagesASetAsideHistoryMayUse() throws {
        let state = try ClipboardState()
        defer { state.restore() }
        try Data("[{\"id\":".utf8).write(to: state.json)
        let h = ClipboardHistory()
        copyImage(png(.green)); h.poll()
        let entry = try #require(h.entries.first)
        h.delete(entry.id)
        #expect(FileManager.default.fileExists(atPath: state.images.appendingPathComponent(entry.text).path))
    }

    @Test func setAsideFileFromAnEarlierBuildKeepsCleanupOff() throws {
        let state = try ClipboardState()
        defer { state.restore() }
        let image = state.images.appendingPathComponent("staged-\(UUID().uuidString).png")
        try FileManager.default.createDirectory(at: state.images, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: image)
        try Data("[{\"id\":".utf8).write(to: state.json.appendingPathExtension("moving"))
        ClipboardHistory().removeUnreferencedImages()
        #expect(FileManager.default.fileExists(atPath: image.path))
    }

    @Test func historyThatCannotBeMovedAsideIsNeverOverwritten() throws {
        let state = try ClipboardState()
        let dir = Paths.supportDir.path
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir)
            state.restore()
        }
        let corrupt = Data("[{\"id\":".utf8)
        try corrupt.write(to: state.json)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir)
        let h = ClipboardHistory()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir)
        Pasteboard.board.clearContents()
        Pasteboard.board.setString("new-\(UUID().uuidString)", forType: .string)
        h.poll()
        #expect(try Data(contentsOf: state.json) == corrupt)
    }

    @Test func zeroClearAfterNeverClears() async throws {
        Pasteboard.copySecret("stay", clearAfter: 0)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(Pasteboard.board.string(forType: .string) == "stay")
    }

    @Test func unknownKindsRoundTrip() throws {
        let json = #"[{"id":"1","kind":"future","text":"x","date":1,"pinned":false}]"#
        let entries = try JSONDecoder().decode([ClipboardHistory.Entry].self, from: Data(json.utf8))
        #expect(entries.first?.kind.raw == "future")
        let again = String(decoding: try JSONEncoder().encode(entries), as: UTF8.self)
        #expect(again.contains(#""kind":"future""#))
        #expect(ClipboardHistory.Kind.classify("https://x.y") == .link)
        #expect(ClipboardHistory.Kind.classify("#a1b2c3") == .color)
        #expect(ClipboardHistory.Kind.classify("https://x y") == .text)
    }

    @Test func zeroMaxItemsStillKeepsTheNewestEntry() {
        let h = ClipboardHistory()
        h.config.maxItems = 0
        Pasteboard.board.clearContents()
        Pasteboard.board.setString("newest-\(UUID().uuidString)", forType: .string)
        h.poll()
        #expect(h.entries.first?.text.hasPrefix("newest-") == true)
    }
}
}
