import AppKit

/// 1Password through the `op` CLI. The item list is cached for 5 minutes; concurrent refreshes share one `op` run.
@MainActor
final class OnePassword {
    static let shared = OnePassword()
    var config = OnePasswordConfig()

    struct OPItem: Decodable {
        struct Vault: Decodable {
            let id: String
            let name: String
        }

        struct URLEntry: Decodable {
            let href: String
            let primary: Bool?
        }

        let id: String
        let title: String
        let category: Category
        let vault: Vault
        let additionalInformation: String?
        let urls: [URLEntry]?

        enum CodingKeys: String, CodingKey {
            case id, title, category, vault, urls
            case additionalInformation = "additional_information"
        }

        var website: String? { urls?.first(where: { $0.primary == true })?.href ?? urls?.first?.href }
    }

    /// `op` item categories; unknown ones keep their raw name.
    struct Category: Decodable, Equatable {
        let raw: String

        init(from decoder: Decoder) throws { raw = try decoder.singleValueContainer().decode(String.self) }

        static let login = "LOGIN", password = "PASSWORD", apiCredential = "API_CREDENTIAL"

        /// Field label and action name of the item's secret, if it has one.
        var secret: (field: String, label: String)? {
            switch raw {
            case Self.login, Self.password: return ("password", "Password")
            case Self.apiCredential: return ("credential", "Credential")
            default: return nil
            }
        }

        var hasUsernameAndOTP: Bool { raw == Self.login }

        var symbol: String {
            switch raw {
            case Self.login: return "key"
            case Self.password: return "lock"
            case Self.apiCredential: return "chevron.left.forwardslash.chevron.right"
            case "CREDIT_CARD": return "creditcard"
            case "SECURE_NOTE": return "note.text"
            case "SSH_KEY": return "terminal"
            default: return "doc"
            }
        }

        var displayName: String { raw.replacingOccurrences(of: "_", with: " ").capitalized }
    }

    private var cached: [OPItem] = []
    private var cachedAt = Date.distantPast
    private var accountUUID: String?
    private var lastError: String?
    private var refreshing: Task<Void, Never>?

    private var baseArgs: [String] { config.account.map { ["--account", $0] } ?? [] }

    /// `OP_SERVICE_ACCOUNT_TOKEN` is removed unless `use_service_account`.
    private func opRun(_ args: [String], timeout: TimeInterval = 30) async throws -> Data {
        try await Shell.run(
            config.op,
            args,
            unset: config.useServiceAccount ? [] : ["OP_SERVICE_ACCOUNT_TOKEN"],
            timeout: timeout
        )
    }

    func refresh() async {
        if let pending = refreshing { return await pending.value }
        if !cached.isEmpty && Date().timeIntervalSince(cachedAt) < 300 { return }
        let task = Task { await load() }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func load() async {
        do {
            let data = try await opRun(["item", "list", "--format", "json"] + baseArgs, timeout: 60)
            cached = try JSONDecoder().decode([OPItem].self, from: data)
            cachedAt = Date()
            lastError = nil
            if accountUUID == nil,
                let who = try? await opRun(["whoami", "--format", "json"] + baseArgs),
                let obj = try? JSONSerialization.jsonObject(with: who) as? [String: Any]
            {
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

    private func copySecret(_ label: String, _ get: @escaping () async throws -> String) -> Action {
        Action(title: "Copy \(label)") {
            Task { @MainActor in
                do {
                    let v = try await get()
                    guard !v.isEmpty else {
                        Launcher.shared?.toast("No \(label.lowercased()) on this item")
                        return
                    }
                    let clearAfter = self.config.clearAfter
                    Pasteboard.copySecret(v, clearAfter: clearAfter)
                    Launcher.shared?.toast(
                        clearAfter > 0 ? "\(label) copied, clears in \(clearAfter)s" : "\(label) copied"
                    )
                } catch {
                    Launcher.shared?.toast("1Password: \(error.localizedDescription)")
                }
            }
            return .stay
        }
    }

    var items: [Item] {
        if cached.isEmpty, let e = lastError {
            return [
                Item(
                    id: "op:error",
                    title: "1Password unavailable",
                    subtitle: e,
                    icon: .symbol("exclamationmark.triangle")
                )
            ]
        }
        return cached.map(item)
    }

    private func item(_ it: OPItem) -> Item {
        let id = "op:" + it.id
        var actions: [Action] = []
        if let secret = it.category.secret {
            actions.append(copySecret(secret.label) { try await self.field(it.id, secret.field) })
        }
        if it.category.hasUsernameAndOTP {
            actions.append(copySecret("Username") { try await self.field(it.id, "username") })
            actions.append(copySecret("One-Time Password") { try await self.otp(it.id) })
        }
        actions.append(
            Action(title: "Open in 1Password") {
                var url = "onepassword://view-item/?v=\(it.vault.id)&i=\(it.id)"
                if let a = self.accountUUID { url += "&a=\(a)" }
                Effects.open(URL(string: url)!)
                return .close
            }
        )
        if let href = it.website {
            actions.append(
                Action(title: "Open Website") {
                    openURL(href)
                    return .close
                }
            )
        }
        let details = [it.additionalInformation, it.vault.name].compactMap { $0 }.filter { !$0.isEmpty }
        return Item(
            id: id,
            title: it.title,
            subtitle: details.joined(separator: " · "),
            icon: .symbol(it.category.symbol),
            keywords: (it.urls ?? []).map(\.href) + [it.additionalInformation ?? ""],
            accessory: it.category.displayName,
            actions: actions,
            historyKey: id
        )
    }
}
