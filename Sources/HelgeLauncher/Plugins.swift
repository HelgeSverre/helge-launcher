import AppKit

/// External plugin protocol:
///   `<exec> <query>` (also $HL_QUERY) prints JSON on stdout:
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
        Item(id: "plugin:" + p.name, title: p.name, subtitle: "Plugin", icon: icon(p.icon ?? "puzzlepiece.extension"),
             keywords: [p.prefix].compactMap { $0 }, accessory: "Plugin", opens: .plugin(p.name))
    }

    static func query(_ p: PluginConfig, _ q: String) async -> [Item] {
        do {
            let data = try await Shell.run(Paths.expand(p.exec), [q], env: ["HL_QUERY": q], timeout: 15)
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

    private static func action(_ a: PAction) -> Action {
        Action(title: a.title) {
            if let o = a.open { _ = openURL(o) }
            if let c = a.copy { Pasteboard.copy(c) }
            if let p = a.paste { Pasteboard.paste(p) }
            if let r = a.run { Task { _ = try? await Shell.run("/bin/zsh", ["-lc", r]) } }
            return false
        }
    }

    static func icon(_ s: String) -> ItemIcon {
        if s.hasPrefix("/") || s.hasPrefix("~") { return .file(NSString(string: s).expandingTildeInPath) }
        if s.unicodeScalars.first?.properties.isEmojiPresentation == true { return .emoji(s) }
        return .symbol(s)
    }
}
