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
        #expect(loaded.files.map(\.lastPathComponent) == ["config.toml", "extra.toml"])

        try #"[[snippet]]\#nname = "a"\#ntext = "b""#.write(to: d.appendingPathComponent("extra.toml"), atomically: true, encoding: .utf8)
        let fixed = ConfigLoader.load(from: d)
        #expect(fixed.error == nil && fixed.config?.snippet.map(\.name) == ["a"])
    }

    @Test func brokenIncludeReportsTheFile() throws {
        let d = try dir(["config.toml": #"include = ["extra.toml"]"#, "extra.toml": "[[snippet]\n"])
        let loaded = ConfigLoader.load(from: d)
        #expect(loaded.error?.contains("extra.toml") == true)
        #expect(loaded.files.count == 2)
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

/// Every test that writes the system pasteboard runs in here, one at a time.
@Suite(.serialized) @MainActor struct PasteboardTests {}

extension PasteboardTests {
@Suite @MainActor struct ClipboardImageTests {
    func png(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 4, height: 4), flipped: false) { r in color.setFill(); r.fill(); return true }
    }

    func copyImage(_ image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    @Test func sameImageIsOneEntryAndDeleteRemovesTheFile() throws {
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
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
        #expect(entry.kind == "image" && newFiles.contains(entry.text))
        h.delete(entry.id)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(entry.text).path))
    }

    @Test func restoringAMissingImageDropsItAndKeepsTheClipboard() throws {
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        let h = ClipboardHistory()
        copyImage(png(.blue)); h.poll()
        let entry = try #require(h.entries.first)
        try FileManager.default.removeItem(at: Paths.supportDir.appendingPathComponent("clipboard-images").appendingPathComponent(entry.text))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("keep me", forType: .string)
        #expect(h.restore(entry) == false)
        #expect(NSPasteboard.general.string(forType: .string) == "keep me")
        #expect(!h.entries.contains { $0.id == entry.id })
    }

    @Test func corruptHistoryKeepsItsImages() throws {
        let fm = FileManager.default
        let json = Paths.supportDir.appendingPathComponent("clipboard.json")
        let image = Paths.supportDir.appendingPathComponent("clipboard-images/keep-\(UUID().uuidString).png")
        let aside = json.appendingPathExtension("corrupt")
        let saved = try? Data(contentsOf: json)
        defer {
            try? fm.removeItem(at: image)
            try? fm.removeItem(at: aside)
            if let saved { try? saved.write(to: json) } else { try? fm.removeItem(at: json) }
        }
        try fm.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("png".utf8).write(to: image)
        try Data("[{\"id\":".utf8).write(to: json)
        let h = ClipboardHistory()
        h.removeUnreferencedImages()
        #expect(fm.fileExists(atPath: image.path))
        #expect(fm.fileExists(atPath: aside.path))
        #expect(h.entries.isEmpty)

        // Next launch: a fresh history exists, the set-aside file still does.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("after-\(UUID().uuidString)", forType: .string)
        h.poll()
        ClipboardHistory().removeUnreferencedImages()
        #expect(fm.fileExists(atPath: image.path))

        // Once the set-aside file is gone, cleanup resumes.
        try fm.removeItem(at: aside)
        ClipboardHistory().removeUnreferencedImages()
        #expect(!fm.fileExists(atPath: image.path))
    }

    @Test func zeroClearAfterNeverClears() async throws {
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        Pasteboard.copy("stay")
        Pasteboard.clear(after: 0, ifStill: "stay")
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(NSPasteboard.general.string(forType: .string) == "stay")
    }

    @Test func zeroMaxItemsStillKeepsTheNewestEntry() {
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        let h = ClipboardHistory()
        h.config.maxItems = 0
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("newest-\(UUID().uuidString)", forType: .string)
        h.poll()
        #expect(h.entries.first?.text.hasPrefix("newest-") == true)
    }
}
}
