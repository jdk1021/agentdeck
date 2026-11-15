import Foundation

/// Display identity from the selected CLI home. Credentials never enter the registry or UI.
enum AccountIdentity {
    static func email(provider: String, account: Account, userHome: URL) -> String? {
        let home = URL(fileURLWithPath: account.home)
        switch provider {
        case "claude":
            let legacy = home.appendingPathComponent(".config.json")
            let profile = FileManager.default.fileExists(atPath: legacy.path) ? legacy
                : (account.primary ? userHome.appendingPathComponent(".claude.json") : home.appendingPathComponent(".claude.json"))
            return address(read(profile)["oauthAccount"]["emailAddress"])
        case "codex":
            let auth = read(home.appendingPathComponent("auth.json"))
            // An API-key login may retain a previous ChatGPT token alongside it.
            if auth["auth_mode"].string == "apikey" || (auth["auth_mode"].string.isEmpty && !auth["OPENAI_API_KEY"].string.isEmpty) { return nil }
            let parts = auth["tokens"]["id_token"].string.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            guard let data = Data(base64Encoded: payload), let claims = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
            return address(claims["email"])
        case "grok":
            let auth = read(home.appendingPathComponent("auth.json"))
            return address(auth["email"]) ?? address(auth["user"]["email"]) ?? address(auth["account"]["email"])
        default: return nil
        }
    }

    private static func read(_ url: URL) -> JSONValue {
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .null }
        return value
    }

    private static func address(_ value: JSONValue) -> String? {
        let email = value.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@"), email.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return email
    }
}
