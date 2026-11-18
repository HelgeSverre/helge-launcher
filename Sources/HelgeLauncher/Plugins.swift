import AppKit

/// Protocol: docs/plugins.md.
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

    static func query(_ p: PluginConfig, _ q: String) async -> [Item] {
        do {
            // `~` expanded; runs in the config directory.
            let program = NSString(string: p.exec[0]).expandingTildeInPath
            // A missing working directory fails the launch.
            try? FileManager.default.createDirectory(at: Paths.configDir, withIntermediateDirectories: true)
            let data = try await Shell.run(
                program,
                Array(p.exec.dropFirst()) + [q],
                env: p.env.mapValues { NSString(string: $0).expandingTildeInPath }
                    .merging(["HL_QUERY": q, "HL_CONFIG_DIR": Paths.configDir.path]) { _, new in new },
                cwd: Paths.configDir,
                timeout: 15
            )
            let out = try JSONDecoder().decode(Output.self, from: data)
            return out.items.enumerated().map { i, it in
                Item(
                    id: "plugin:\(p.name):\(it.id ?? "\(i):\(it.title)")",
                    title: it.title,
                    subtitle: it.subtitle ?? "",
                    icon: ItemIcon(spec: it.icon ?? p.icon ?? "circle"),
                    accessory: it.accessory ?? "",
                    actions: (it.actions ?? []).map(action)
                )
            }
        } catch {
            return [
                Item(
                    id: "plugin:error",
                    title: "\(p.name) failed",
                    subtitle: error.localizedDescription,
                    icon: .symbol("exclamationmark.triangle")
                )
            ]
        }
    }

    static func action(_ a: PAction) -> Action {
        let detail = [
            a.open.map { "open \($0)" }, a.copy.map { "copy \($0)" }, a.paste.map { "paste \($0)" },
            a.run.map { "run \($0)" },
        ]
        .compactMap { $0 }.joined(separator: "; ")
        return Action(title: a.title, detail: detail) {
            if let o = a.open { openURL(o) }
            if let c = a.copy { Pasteboard.copy(c) }
            if let p = a.paste { Pasteboard.paste(p) }
            if let r = a.run { Shell.spawn(r) }
            return .close
        }
    }

}
