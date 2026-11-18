import AppKit

/// External plugin protocol (docs/plugins.md):
///   `<exec…> <query>` (also $HL_QUERY), run from the config directory, prints JSON on stdout:
///   {"items":[{"title":"…","subtitle":"…","icon":"sf.symbol|😀|/path","accessory":"…",
///              "actions":[{"title":"Open","open":"https://…"},{"title":"Copy","copy":"…"},
///                         {"title":"Paste","paste":"…"},{"title":"Run","run":"shell command"}]}]}
enum Plugins {
    struct Output: Decodable { let items: [PItem] }
    struct PItem: Decodable {
        let id: String?
        let title: String
        let subtitle: String?
        let icon: String?
        let accessory: String?
        let actions: [PAction]?
    }
    struct PAction: Decodable {
        let title: String
        let open: String?
        let copy: String?
        let paste: String?
        let run: String?
    }

    static func entry(_ p: PluginConfig) -> Item {
        Item(id: Mode.plugin(p.name).itemID, title: p.name, subtitle: p.prefix.map { "\($0) …" } ?? "", icon: icon(p.icon ?? "puzzlepiece.extension"),
             keywords: [p.prefix].compactMap { $0 }, accessory: "Plugin", opens: .plugin(p.name))
    }

    static func query(_ p: PluginConfig, _ q: String) async -> [Item] {
        do {
            // A lone path may use ~; everything runs from the config directory so relative paths work.
            let program = NSString(string: p.exec[0]).expandingTildeInPath
            // A missing working directory makes the launch itself fail.
            try? FileManager.default.createDirectory(at: Paths.configDir, withIntermediateDirectories: true)
            let data = try await Shell.run(program, Array(p.exec.dropFirst()) + [q],
                                           env: p.env.mapValues { NSString(string: $0).expandingTildeInPath }
                                               .merging(["HL_QUERY": q, "HL_CONFIG_DIR": Paths.configDir.path]) { _, new in new },
                                           cwd: Paths.configDir, timeout: 15)
            let out = try JSONDecoder().decode(Output.self, from: data)
            return out.items.enumerated().map { i, it in
                Item(id: "plugin:\(p.name):\(it.id ?? "\(i):\(it.title)")", title: it.title, subtitle: it.subtitle ?? "",
                     icon: icon(it.icon ?? p.icon ?? "circle"), accessory: it.accessory ?? "",
                     actions: (it.actions ?? []).map(action))
            }
        } catch {
            return [Item(id: "plugin:error", title: "\(p.name) failed", subtitle: error.localizedDescription, icon: .symbol("exclamationmark.triangle"))]
        }
    }

    static func action(_ a: PAction) -> Action {
        let detail = [a.open.map { "open \($0)" }, a.copy.map { "copy \($0)" }, a.paste.map { "paste \($0)" }, a.run.map { "run \($0)" }]
            .compactMap { $0 }.joined(separator: "; ")
        return Action(title: a.title, detail: detail) {
            if let o = a.open { _ = openURL(o) }
            if let c = a.copy { Pasteboard.copy(c) }
            if let p = a.paste { Pasteboard.paste(p) }
            if let r = a.run { Shell.spawn(r) }
            return false
        }
    }

    static func icon(_ s: String) -> ItemIcon {
        if s.hasPrefix("/") || s.hasPrefix("~") { return .file(NSString(string: s).expandingTildeInPath) }
        if s.unicodeScalars.first?.properties.isEmojiPresentation == true { return .emoji(s) }
        return .symbol(s)
    }
}
