import Foundation

/// A folder that tends to grow large, and how to clear it.
struct StorageSpot: Sendable {
    enum Clear: Sendable {
        /// Delete what is inside the folder.
        case contents
        /// Run a command (with zsh -lc) that cleans up properly.
        case command(String)
    }

    var id: String
    var title: String
    /// With `~`.
    var path: String
    /// A word on what it holds or what clearing does.
    var tag: String
    var clear: Clear?

    var url: URL { URL(fileURLWithPath: NSString(string: path).expandingTildeInPath) }

    static let all: [StorageSpot] = [
        .init(id: "android", title: "Android SDK", path: "~/.android", tag: "emulator images"),
        .init(id: "downloads", title: "Downloads", path: "~/Downloads", tag: "review"),
        .init(id: "cache", title: "Tool caches", path: "~/.cache", tag: "safe to clear", clear: .contents),
        .init(id: "caches", title: "App caches", path: "~/Library/Caches", tag: "safe to clear", clear: .contents),
        .init(
            id: "derived",
            title: "Xcode DerivedData",
            path: "~/Library/Developer/Xcode/DerivedData",
            tag: "safe to clear",
            clear: .contents
        ),
        .init(
            id: "simulators",
            title: "iOS Simulators",
            path: "~/Library/Developer/CoreSimulator",
            tag: "delete unavailable",
            clear: .command("xcrun simctl delete unavailable")
        ),
        .init(
            id: "orbstack",
            title: "OrbStack",
            path: "~/Library/Group Containers/HUAQ24HBR6.dev.orbstack",
            tag: "prune unused",
            clear: .command("docker system prune -f")
        ),
        .init(
            id: "npm",
            title: "npm cache",
            path: "~/.npm",
            tag: "safe to clear",
            clear: .command("npm cache clean --force")
        ),
        .init(id: "gradle", title: "Gradle caches", path: "~/.gradle/caches", tag: "safe to clear", clear: .contents),
        .init(
            id: "bun",
            title: "Bun cache",
            path: "~/.bun/install/cache",
            tag: "safe to clear",
            clear: .command("bun pm cache rm")
        ),
        .init(
            id: "pnpm",
            title: "pnpm store",
            path: "~/Library/pnpm/store",
            tag: "prune unused",
            clear: .command("pnpm store prune")
        ),
        .init(id: "cargo", title: "Cargo registry", path: "~/.cargo/registry", tag: "safe to clear", clear: .contents),
        .init(id: "ollama", title: "Ollama models", path: "~/.ollama/models", tag: "review"),
    ]
}

/// Sizes of the storage spots, measured with `du` in the background and kept between launches.
@MainActor
final class StorageScanner {
    static let shared = StorageScanner()

    struct Measured: Codable {
        var bytes: Int64
        var at: Date
    }

    private(set) var sizes: [String: Measured] = [:]
    private(set) var measuring: Set<String> = []
    /// Called after each spot is measured.
    var changed: (() -> Void)?
    private let file: URL

    init(file: URL = Paths.supportDir.appendingPathComponent("storage.json")) {
        self.file = file
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode([String: Measured].self, from: d) {
            sizes = s
        }
    }

    /// Spots that exist, largest first (unmeasured last).
    var spots: [StorageSpot] {
        StorageSpot.all.filter { FileManager.default.fileExists(atPath: $0.url.path) }.sorted {
            (sizes[$0.id]?.bytes ?? -1) > (sizes[$1.id]?.bytes ?? -1)
        }
    }

    var lastMeasured: Date? { sizes.values.map(\.at).max() }

    /// Measures spots older than `maxAge` (all with `maxAge` 0).
    func refresh(maxAge: TimeInterval = 600) {
        guard !Paths.isTestRunner else { return }
        for spot in spots where !measuring.contains(spot.id) {
            if let m = sizes[spot.id], Date().timeIntervalSince(m.at) < maxAge { continue }
            measure(spot)
        }
    }

    func measure(_ spot: StorageSpot) {
        measuring.insert(spot.id)
        let path = spot.url.path
        Task.detached {
            let bytes = StorageScanner.du(path)
            await MainActor.run {
                self.measuring.remove(spot.id)
                if let bytes { self.sizes[spot.id] = Measured(bytes: bytes, at: Date()) }
                self.save()
                self.changed?()
            }
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(sizes) { try? d.write(to: file, options: .atomic) }
    }

    /// `du -sk`: kilobytes in use. Unreadable sub-folders make du exit 1 but still print the total.
    nonisolated static func du(_ path: String) -> Int64? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        p.arguments = ["-sk", path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 600, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        let text = String(decoding: data, as: UTF8.self)
        guard let kb = Int64(text.split(separator: "\t").first ?? "") else { return nil }
        return kb * 1024
    }

    /// Clears a spot, then measures it again. Reports the space freed.
    func clear(_ spot: StorageSpot, done: @escaping (String) -> Void) {
        guard let how = spot.clear, !Paths.isTestRunner else { return }
        let before = sizes[spot.id]?.bytes
        let url = spot.url
        Task {
            switch how {
            case .contents:
                await Task.detached {
                    let fm = FileManager.default
                    for child in (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
                        try? fm.removeItem(at: child)
                    }
                }.value
            case .command(let c):
                _ = try? await Shell.run("/bin/zsh", ["-lc", c], timeout: 600)
            }
            let after = await Task.detached { StorageScanner.du(url.path) }.value
            if let after { sizes[spot.id] = Measured(bytes: after, at: Date()) }
            save()
            changed?()
            if let before, let after, before > after {
                done("Freed \(Fmt.bytes(before - after)) from \(spot.title)")
            } else {
                done("Cleared \(spot.title)")
            }
        }
    }
}
