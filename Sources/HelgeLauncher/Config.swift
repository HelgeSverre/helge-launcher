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

/// An external program speaking the JSON plugin protocol (docs/plugins.md).
/// `exec` is a path (`"plugins/x.sh"`) or an argument list (`["sema", "plugins/x.sema", "--"]`);
/// the query is appended as the last argument. Relative paths resolve against the config directory.
struct PluginConfig: Decodable {
    var name: String
    var exec: [String]
    var prefix: String?
    var icon: String?
    /// Extra environment variables (values may start with ~). The launcher runs outside your
    /// shell, so variables from ~/.zshrc are not visible to plugins unless set here.
    var env: [String: String] = [:]

    enum CodingKeys: String, CodingKey { case name, exec, prefix, icon, env }

    init(name: String, exec: String, prefix: String? = nil, icon: String? = nil, env: [String: String] = [:]) {
        self.name = name
        self.exec = [exec]
        self.prefix = prefix
        self.icon = icon
        self.env = env
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        if let list = try? c.decode([String].self, forKey: .exec) {
            exec = list
        } else {
            exec = [try c.decode(String.self, forKey: .exec)]
        }
        guard !exec.isEmpty, !exec[0].isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .exec, in: c, debugDescription: "plugin \(name): exec is empty")
        }
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
    }
}

struct DynKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

enum Paths {
    /// `~/.config/hl`, or `$HL_CONFIG_DIR` (handy for trying a config or a plugin in isolation).
    static let configDir = URL(fileURLWithPath: NSString(string: ProcessInfo.processInfo.environment["HL_CONFIG_DIR"] ?? "~/.config/hl").expandingTildeInPath)
    static let configFile = configDir.appendingPathComponent("config.toml")
    static let pluginDir = configDir.appendingPathComponent("plugins")
    /// History, clipboard and AI working directory: a temporary directory under test runners, else
    /// `$HL_DATA_DIR` (relative to HOME), else `~/Library/Application Support/HelgeLauncher`.
    static let supportDir: URL = {
        let env = ProcessInfo.processInfo.environment
        let u: URL
        if ["swiftpm-testing-helper", "xctest"].contains(ProcessInfo.processInfo.processName) {
            u = FileManager.default.temporaryDirectory.appendingPathComponent("HelgeLauncherTests-\(getpid())")
        } else if let dir = env["HL_DATA_DIR"] {
            let path = NSString(string: dir).expandingTildeInPath
            u = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(path)
        } else {
            u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HelgeLauncher")
        }
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static func expand(_ p: String, relativeTo dir: URL = configDir) -> String {
        let e = NSString(string: p).expandingTildeInPath
        return e.hasPrefix("/") ? e : dir.appendingPathComponent(e).path
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

    struct Loaded {
        /// nil when a file failed to parse.
        var config: Config?
        var error: String?
        /// Non-fatal problems, such as an include that doesn't exist yet.
        var warnings: [String] = []
        /// Modification date of every file the load read or tried to read, taken before reading it.
        var stamps: [String: Date] = [:]
        var files: [URL] { stamps.keys.sorted().map { URL(fileURLWithPath: $0) } }
    }

    static let defaultSnippets = """
    # Snippets: see docs/snippets.md.
    # [[snippet]]
    # name = "email"
    # text = "you@example.com"

    """

    /// Loads `config.toml` (created with defaults if missing) and its `include`d files, whose
    /// `[[command]]`, `[[snippet]]` and `[[plugin]]` blocks are appended. A missing include counts as empty.
    static func load(from dir: URL = Paths.configDir) -> Loaded {
        let fm = FileManager.default
        let main = dir.appendingPathComponent("config.toml")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: main.path) {
            try? defaultConfig.write(to: main, atomically: true, encoding: .utf8)
            let snippets = dir.appendingPathComponent("snippets.toml")
            if !fm.fileExists(atPath: snippets.path) {
                try? defaultSnippets.write(to: snippets, atomically: true, encoding: .utf8)
            }
        }
        var result = Loaded()
        func read(_ url: URL) throws -> Config {
            result.stamps[url.path] = ConfigWatcher.stamp(url.path)
            return try parse(url)
        }
        var cfg: Config
        do {
            cfg = try read(main)
        } catch {
            result.error = "\(error)"
            return result
        }
        do {
            for inc in cfg.include {
                let url = URL(fileURLWithPath: Paths.expand(inc, relativeTo: dir))
                guard fm.fileExists(atPath: url.path) else {
                    result.stamps[url.path] = .distantPast
                    result.warnings.append("include \(inc) not found")
                    continue
                }
                let extra = try read(url)
                cfg.command += extra.command
                cfg.snippet += extra.snippet
                cfg.plugin += extra.plugin
            }
        } catch {
            result.error = "\(error)"
            return result
        }
        result.config = cfg
        return result
    }

    static func parse(_ url: URL) throws -> Config {
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

    init(onChange: @escaping () -> Void) {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Self.stamps(of: self.stamps.keys)
            if now != self.stamps { self.stamps = now; onChange() }
        }
    }

    /// Watches these files, compared against the modification dates the load saw.
    func reset(stamps: [String: Date]) { self.stamps = stamps }

    static func stamp(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
    }

    private static func stamps<S: Sequence>(of paths: S) -> [String: Date] where S.Element == String {
        Dictionary(uniqueKeysWithValues: paths.map { ($0, stamp($0)) })
    }
}

/// Parses config TOML from a string (used by tests and `parse`).
enum TOMLDecoderShim {
    static func decode(_ text: String) throws -> Config { try TOMLDecoder().decode(Config.self, from: text) }
}
