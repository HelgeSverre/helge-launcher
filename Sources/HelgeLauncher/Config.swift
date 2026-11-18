import Foundation
import TOMLKit

/// `~/.config/hl/config.toml`. A missing key keeps the default; a key of the wrong type is an error.
struct Config: Decodable {
    var hotkey = "cmd+space"
    var launchAtLogin = false
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
        hotkey = try c.value(.hotkey, or: hotkey)
        launchAtLogin = try c.value(.launchAtLogin, or: launchAtLogin)
        include = try c.value(.include, or: include)
        ai = try c.value(.ai, or: ai)
        clipboard = try c.value(.clipboard, or: clipboard)
        onepassword = try c.value(.onepassword, or: onepassword)
        cleanshot = try c.value(.cleanshot, or: cleanshot)
        command = try c.value(.command, or: command)
        snippet = try c.value(.snippet, or: snippet)
        plugin = try c.value(.plugin, or: plugin)
    }
}

struct AIConfig: Decodable {
    var enabled = true
    var model = "opencode-go/deepseek-v4.1-flash"
    var opencode = "opencode"
    var system: String?

    enum CodingKeys: String, CodingKey { case enabled, model, opencode, system }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.value(.enabled, or: enabled)
        model = try c.value(.model, or: model)
        opencode = try c.value(.opencode, or: opencode)
        system = try c.decodeIfPresent(String.self, forKey: .system)
    }

    var providerID: String { String(model.split(separator: "/", maxSplits: 1).first ?? "") }
    var modelID: String { model.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) ?? model }
}

struct ClipboardConfig: Decodable {
    var enabled = true
    var hotkey: String?
    var maxItems = 500
    var ignoreApps = ["com.1password.1password", "com.agilebits.onepassword7"]

    enum CodingKeys: String, CodingKey {
        case enabled, hotkey
        case maxItems = "max_items"
        case ignoreApps = "ignore_apps"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.value(.enabled, or: enabled)
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey)
        maxItems = try c.value(.maxItems, or: maxItems)
        ignoreApps = try c.value(.ignoreApps, or: ignoreApps)
    }
}

struct OnePasswordConfig: Decodable {
    var enabled = true
    var op = "op"
    var account: String?
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
        enabled = try c.value(.enabled, or: enabled)
        op = try c.value(.op, or: op)
        account = try c.decodeIfPresent(String.self, forKey: .account)
        clearAfter = try c.value(.clearAfter, or: clearAfter)
        useServiceAccount = try c.value(.useServiceAccount, or: useServiceAccount)
    }
}

struct CleanShotConfig: Decodable {
    var enabled = true

    enum CodingKeys: String, CodingKey { case enabled }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.value(.enabled, or: enabled)
    }
}

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

/// `exec`: a path or an argument list; the query is appended as the last argument.
struct PluginConfig: Decodable {
    var name: String
    var exec: [String]
    var prefix: String?
    var icon: String?
    /// Values may start with `~`.
    var env: [String: String] = [:]

    enum CodingKeys: String, CodingKey { case name, exec, prefix, icon, env }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        if let list = try? c.decode([String].self, forKey: .exec) {
            exec = list
        } else {
            exec = [try c.decode(String.self, forKey: .exec)]
        }
        guard !exec.isEmpty, !exec[0].isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .exec,
                in: c,
                debugDescription: "plugin \(name): exec is empty"
            )
        }
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        env = try c.value(.env, or: env)
    }

    init(name: String, exec: [String], prefix: String? = nil, icon: String? = nil, env: [String: String] = [:]) {
        precondition(!exec.isEmpty && !exec[0].isEmpty, "plugin \(name): exec is empty")
        self.name = name
        self.exec = exec
        self.prefix = prefix
        self.icon = icon
        self.env = env
    }
}

extension KeyedDecodingContainer {
    /// The decoded value, or `fallback` when the key is absent.
    func value<T: Decodable>(_ key: Key, or fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}

enum Paths {
    /// `$HL_CONFIG_DIR`, else `~/.config/hl`.
    static let configDir: URL = {
        let dir = ProcessInfo.processInfo.environment["HL_CONFIG_DIR"] ?? "~/.config/hl"
        return URL(fileURLWithPath: NSString(string: dir).expandingTildeInPath)
    }()

    static let configFile = configDir.appendingPathComponent("config.toml")
    static let isTestRunner = ["swiftpm-testing-helper", "xctest"].contains(ProcessInfo.processInfo.processName)
    static let isAppBundle = Bundle.main.bundlePath.hasSuffix(".app")

    /// History, clipboard and AI working directory: a temporary directory under test runners, else
    /// `$HL_DATA_DIR` (relative to HOME), else `~/Library/Application Support/HelgeLauncher`.
    static let supportDir: URL = {
        let fm = FileManager.default
        let u: URL
        if isTestRunner {
            u = fm.temporaryDirectory.appendingPathComponent("HelgeLauncherTests-\(getpid())")
        } else if let dir = ProcessInfo.processInfo.environment["HL_DATA_DIR"] {
            u = URL(fileURLWithPath: resolve(dir, against: URL(fileURLWithPath: NSHomeDirectory())))
        } else {
            u = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(
                "HelgeLauncher"
            )
        }
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    /// `~` expanded; a relative path is taken relative to `dir`.
    static func resolve(_ path: String, against dir: URL) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        return expanded.hasPrefix("/") ? expanded : dir.appendingPathComponent(expanded).path
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

    static let defaultSnippets = """
        # Snippets: see docs/snippets.md.
        # [[snippet]]
        # name = "email"
        # text = "you@example.com"

        """

    struct Loaded {
        /// nil when a file failed to parse.
        var config: Config?
        var error: String?
        /// Non-fatal problems (missing includes).
        var warnings: [String] = []
        /// Modification date of every file read or looked for, taken before reading it.
        var stamps: [String: Date] = [:]
    }

    /// Reads `config.toml` (written with defaults if missing) and appends the command, snippet and
    /// plugin blocks of its includes. A missing include is a warning.
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
            result.stamps[url.path] = stamp(url.path)
            return try parse(url)
        }
        do {
            var cfg = try read(main)
            for inc in cfg.include {
                let url = URL(fileURLWithPath: Paths.resolve(inc, against: dir))
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
            result.config = cfg
        } catch {
            result.error = "\(error)"
        }
        return result
    }

    static func parse(_ url: URL) throws -> Config {
        do {
            return try parse(text: try String(contentsOf: url, encoding: .utf8))
        } catch {
            throw NSError(
                domain: "config",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent): \(error)"]
            )
        }
    }

    static func parse(text: String) throws -> Config {
        try TOMLDecoder().decode(Config.self, from: text)
    }

    static func stamp(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
    }
}

/// Polls the loaded files' modification dates once a second.
final class ConfigWatcher {
    private var timer: Timer?
    private var stamps: [String: Date] = [:]

    init(onChange: @escaping () -> Void) {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Dictionary(uniqueKeysWithValues: self.stamps.keys.map { ($0, ConfigLoader.stamp($0)) })
            if now != self.stamps {
                self.stamps = now
                onChange()
            }
        }
    }

    /// Compares against the modification dates the load saw.
    func reset(stamps: [String: Date]) { self.stamps = stamps }
}
