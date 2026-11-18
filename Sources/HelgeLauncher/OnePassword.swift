import AppKit

/// 1Password via the `op` CLI (desktop-app integration handles auth/biometrics).
final class OnePassword {
    static let shared = OnePassword()
    var config = OnePasswordConfig()

    struct OPItem: Decodable {
        struct Vault: Decodable { let id: String; let name: String }
        struct URLEntry: Decodable { let href: String; let primary: Bool? }
        let id: String
        let title: String
        let category: String
        let vault: Vault
        let additional_information: String?
        let urls: [URLEntry]?
    }

    private(set) var cached: [OPItem] = []
    private var cachedAt = Date.distantPast
    private var accountUUID: String?
    private(set) var lastError: String?
    private var loading = false

    private var baseArgs: [String] { config.account.map { ["--account", $0] } ?? [] }

    /// Uses the 1Password desktop-app integration; a service-account token in the env would hide personal vaults.
    private func opRun(_ args: [String], timeout: TimeInterval = 30) async throws -> Data {
        try await Shell.run(config.op, args, unset: config.useServiceAccount ? [] : ["OP_SERVICE_ACCOUNT_TOKEN"], timeout: timeout)
    }

    func refresh(force: Bool = false) async {
        if loading || (!force && Date().timeIntervalSince(cachedAt) < 300 && !cached.isEmpty) { return }
        loading = true
        defer { loading = false }
        do {
            let data = try await opRun(["item", "list", "--format", "json"] + baseArgs, timeout: 60)
            cached = try JSONDecoder().decode([OPItem].self, from: data)
            cachedAt = Date()
            lastError = nil
            if accountUUID == nil,
               let who = try? await opRun(["whoami", "--format", "json"] + baseArgs),
               let obj = try? JSONSerialization.jsonObject(with: who) as? [String: Any] {
                accountUUID = obj["account_uuid"] as? String
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func read(_ ref: String) async throws -> String {
        let d = try await opRun(["read", "--no-newline", ref] + baseArgs)
        return String(decoding: d, as: UTF8.self)
    }

    private func field(_ id: String, _ label: String) async throws -> String {
        let d = try await opRun(["item", "get", id, "--fields", "label=\(label)", "--reveal"] + baseArgs)
        return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func otp(_ id: String) async throws -> String {
        let d = try await opRun(["item", "get", id, "--otp"] + baseArgs)
        return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor private func copySecret(_ label: String, _ get: @escaping () async throws -> String) -> Action {
        Action(title: "Copy \(label)") {
            Task { @MainActor in
                do {
                    let v = try await get()
                    guard !v.isEmpty else { Launcher.shared?.toast("No \(label.lowercased()) on this item"); return }
                    Pasteboard.copy(v, concealed: true)
                    Pasteboard.clear(after: self.config.clearAfter, ifStill: v)
                    Launcher.shared?.toast("\(label) copied, clears in \(self.config.clearAfter)s")
                } catch {
                    Launcher.shared?.toast("1Password: \(error.localizedDescription)")
                }
            }
            return true
        }
    }

    @MainActor var items: [Item] {
        if cached.isEmpty, let e = lastError {
            return [Item(id: "op:error", title: "1Password unavailable", subtitle: e, icon: .symbol("exclamationmark.triangle"))]
        }
        return cached.map { it in
            let id = "op:" + it.id
            var actions: [Action] = []
            let record = { History.shared.record(id) }
            if it.category == "LOGIN" || it.category == "PASSWORD" || it.category == "API_CREDENTIAL" {
                actions.append(copySecret(it.category == "API_CREDENTIAL" ? "Credential" : "Password") {
                    record()
                    return try await self.field(it.id, it.category == "API_CREDENTIAL" ? "credential" : "password")
                })
            }
            if it.category == "LOGIN" {
                actions.append(copySecret("Username") { record(); return try await self.field(it.id, "username") })
                actions.append(copySecret("One-Time Password") { record(); return try await self.otp(it.id) })
            }
            actions.append(Action(title: "Open in 1Password") {
                record()
                var url = "onepassword://view-item/?v=\(it.vault.id)&i=\(it.id)"
                if let a = self.accountUUID { url += "&a=\(a)" }
                NSWorkspace.shared.open(URL(string: url)!)
                return false
            })
            if let href = it.urls?.first(where: { $0.primary == true })?.href ?? it.urls?.first?.href {
                actions.append(Action(title: "Open Website") { _ = openURL(href); return false })
            }
            return Item(
                id: id, title: it.title,
                subtitle: [it.additional_information, it.vault.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                icon: .symbol(symbol(it.category)),
                keywords: (it.urls ?? []).map(\.href) + [it.additional_information ?? ""],
                accessory: it.category.replacingOccurrences(of: "_", with: " ").capitalized,
                actions: actions)
        }
    }

    private func symbol(_ category: String) -> String {
        switch category {
        case "LOGIN": return "key"
        case "PASSWORD": return "lock"
        case "API_CREDENTIAL": return "chevron.left.forwardslash.chevron.right"
        case "CREDIT_CARD": return "creditcard"
        case "SECURE_NOTE": return "note.text"
        case "SSH_KEY": return "terminal"
        default: return "doc"
        }
    }
}
