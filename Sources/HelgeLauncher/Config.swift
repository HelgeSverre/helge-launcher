import Foundation
import TOMLKit

struct Config: Decodable {
    var hotkey: String = "cmd+space"
    var launchAtLogin: Bool = false
    var include: [String] = []
    var ai = AIConfig()
    var clipboard = ClipboardConfig()
    var onepassword = OnePasswordConfig()
    var cleanshot = CleanShotConfig()
    var command: [CommandConfig] = []
    var snippet: [SnippetConfig] = []
    var plugin: [PluginConfig] = []

    enum CodingKeys: String, CodingKey {
        case hotkey, include, ai, clipboard, onepassword, cleanshot, command, snippet, plugin
        case launchAtLogin = "launch_at_login"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? hotkey
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? launchAtLogin
        include = try c.decodeIfPresent([String].self, forKey: .include) ?? []
        ai = try c.decodeIfPresent(AIConfig.self, forKey: .ai) ?? ai
        clipboard = try c.decodeIfPresent(ClipboardConfig.self, forKey: .clipboard) ?? clipboard
        onepassword = try c.decodeIfPresent(OnePasswordConfig.self, forKey: .onepassword) ?? onepassword
        cleanshot = try c.decodeIfPresent(CleanShotConfig.self, forKey: .cleanshot) ?? cleanshot
        command = try c.decodeIfPresent([CommandConfig].self, forKey: .command) ?? []
        snippet = try c.decodeIfPresent([SnippetConfig].self, forKey: .snippet) ?? []
        plugin = try c.decodeIfPresent([PluginConfig].self, forKey: .plugin) ?? []
    }
}

struct AIConfig: Decodable {
    var enabled = true
    var model = "opencode-go/deepseek-v4.1-flash"
    var opencode = "opencode"
    var system: String? = nil

    enum CodingKeys: String, CodingKey { case enabled, model, opencode, system }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? model
        opencode = try c.decodeIfPresent(String.self, forKey: .opencode) ?? opencode
        system = try c.decodeIfPresent(String.self, forKey: .system)
    }

    var providerID: String { String(model.split(separator: "/", maxSplits: 1).first ?? "") }
    var modelID: String { model.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) ?? model }
}

struct ClipboardConfig: Decodable {
    var enabled = true
    var hotkey: String? = nil
    var maxItems = 500
    var ignoreApps: [String] = ["com.1password.1password", "com.agilebits.onepassword7"]

    enum CodingKeys: String, CodingKey {
        case enabled, hotkey
        case maxItems = "max_items"
        case ignoreApps = "ignore_apps"
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey)
        maxItems = try c.decodeIfPresent(Int.self, forKey: .maxItems) ?? maxItems
        ignoreApps = try c.decodeIfPresent([String].self, forKey: .ignoreApps) ?? ignoreApps
    }
}

struct OnePasswordConfig: Decodable {
    var enabled = true
    var op = "op"
    var account: String? = nil
    var clearAfter = 90
    var useServiceAccount = false

    enum CodingKeys: String, CodingKey {
        case enabled, op, account
        case clearAfter = "clear_after"
        case useServiceAccount = "use_service_account"
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        op = try c.decodeIfPresent(String.self, forKey: .op) ?? op
        account = try c.decodeIfPresent(String.self, forKey: .account)
        clearAfter = try c.decodeIfPresent(Int.self, forKey: .clearAfter) ?? clearAfter
        useServiceAccount = try c.decodeIfPresent(Bool.self, forKey: .useServiceAccount) ?? false
    }
}

struct CleanShotConfig: Decodable {
    var enabled = true
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynKey.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: DynKey("enabled")) ?? true
    }
}

/// A user command: open a URL/app/file or run a shell command.
struct CommandConfig: Decodable {
    var name: String
    var open: String?
    var run: String?
    var hotkey: String?
    var keywords: [String]?
    var icon: String?
}

struct SnippetConfig: Decodable {
    var name: String
    var text: String
    var keyword: String?
}

/// An external program speaking the JSON plugin protocol (see README).
struct PluginConfig: Decodable {
    var name: String
    var exec: String
    var prefix: String?
    var icon: String?
}

struct DynKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

enum Paths {
    static let configDir = URL(fileURLWithPath: NSString(string: "~/.config/hl").expandingTildeInPath)
    static let configFile = configDir.appendingPathComponent("config.toml")
    static let pluginDir = configDir.appendingPathComponent("plugins")
    static let supportDir: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HelgeLauncher")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static func expand(_ p: String) -> String {
        let e = NSString(string: p).expandingTildeInPath
        return e.hasPrefix("/") ? e : configDir.appendingPathComponent(e).path
    }
}

enum ConfigLoader {
    static let defaultConfig = """
    # Helge Launcher config. Saved changes apply immediately.
    hotkey = "cmd+space"
    launch_at_login = false
    include = ["snippets.toml"]

    [ai]
    model = "opencode-go/deepseek-v4.1-flash"

    [clipboard]
    max_items = 500

    [onepassword]
    clear_after = 90


    # [[plugin]]
    # name = "Example"
    # exec = "plugins/example.sh"
    # prefix = "ex"
    """

    /// Loads config.toml plus any `include`d files; included arrays are appended.
    static func load() -> (Config, String?) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.configDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: Paths.configFile.path) {
            try? defaultConfig.write(to: Paths.configFile, atomically: true, encoding: .utf8)
        }
        do {
            var cfg = try parse(Paths.configFile)
            for inc in cfg.include {
                let extra = try parse(URL(fileURLWithPath: Paths.expand(inc)))
                cfg.command += extra.command
                cfg.snippet += extra.snippet
                cfg.plugin += extra.plugin
            }
            return (cfg, nil)
        } catch {
            return (Config(), "\(error)")
        }
    }

    private static func parse(_ url: URL) throws -> Config {
        let text = try String(contentsOf: url, encoding: .utf8)
        do {
            return try TOMLDecoder().decode(Config.self, from: text)
        } catch {
            throw NSError(domain: "config", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent): \(error)"])
        }
    }
}

/// Polls modification dates of the config files; robust against atomic saves and in-place writes.
final class ConfigWatcher {
    private var timer: Timer?
    private var stamps: [String: Date] = [:]
    var files: [URL] = []

    init(onChange: @escaping () -> Void) {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = self.snapshot()
            if now != self.stamps { self.stamps = now; onChange() }
        }
    }

    func reset(files: [URL]) {
        self.files = files
        stamps = snapshot()
    }

    private func snapshot() -> [String: Date] {
        var d: [String: Date] = [:]
        for f in files {
            d[f.path] = (try? FileManager.default.attributesOfItem(atPath: f.path)[.modificationDate] as? Date) ?? .distantPast
        }
        return d
    }
}
