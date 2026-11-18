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
        #expect(loaded.error == nil)
        #expect(loaded.config?.hotkey == "cmd+space")
        #expect(FileManager.default.fileExists(atPath: d.appendingPathComponent("config.toml").path))
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
        let red = png(.red)
        copyImage(red); h.poll()
        copyImage(red); h.poll()
        let images = h.entries.filter { $0.kind == "image" && h.entries.first?.text == $0.text }
        #expect(images.count == 1)

        let file = Paths.supportDir.appendingPathComponent("clipboard-images").appendingPathComponent(try #require(images.first).text)
        #expect(FileManager.default.fileExists(atPath: file.path))
        h.delete(images[0].id)
        #expect(!FileManager.default.fileExists(atPath: file.path))
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
