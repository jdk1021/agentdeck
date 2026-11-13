import Foundation

public final class AccountManager: @unchecked Sendable {
    public let store: DiskStore
    public let runtime: CollectorRuntime
    public let resolver: CLIResolver
    public init(store: DiskStore, runtime: CollectorRuntime, resolver: CLIResolver = CLIResolver()) {
        self.store = store; self.runtime = runtime; self.resolver = resolver
    }
    private func check(_ provider: Provider) throws {
        guard provider.supportsAccounts else { throw DeckError.message("\(provider.name) has usage support; upstream does not provide multi-account switching.") }
    }
    public func registryURL(_ provider: Provider) -> URL { store.paths.accounts.appendingPathComponent(provider.id + ".json") }
    public func registry(_ provider: Provider) throws -> AccountRegistry {
        try check(provider)
        var initial = AccountRegistry()
        initial.accounts = [Account(id: "primary", label: "Primary", home: store.paths.home.appendingPathComponent("." + provider.id).path, primary: true, pendingLogin: false)]
        return try store.read(AccountRegistry.self, at: registryURL(provider), fallback: initial)
    }
    @discardableResult public func update<T>(_ provider: Provider, _ body: (inout AccountRegistry) throws -> T) throws -> T {
        try check(provider)
        return try store.locked(registryURL(provider)) {
            var registry = try self.registry(provider)
            let result = try body(&registry)
            try store.write(registry, to: registryURL(provider))
            return result
        }
    }
    public func add(_ provider: Provider, label: String) throws -> Account {
        try check(provider)
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 80 else { throw DeckError.message("Account name must contain 1–80 characters") }
        return try update(provider) { registry in
            let id = UUID().uuidString.lowercased()
            let home = store.paths.accounts.appendingPathComponent(provider.id).appendingPathComponent(id)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let account = Account(id: id, label: label, home: home.path)
            try prepareHome(provider, account: account)
            registry.accounts.append(account)
            return account
        }
    }
    public func prepareHome(_ provider: Provider, account: Account) throws {
        guard !account.primary else { return }
        let primary = store.paths.home.appendingPathComponent("." + provider.id)
        let target = URL(fileURLWithPath: account.home)
        let directories: [String]
        let files: [String]
        switch provider.id {
        case "claude":
            directories = ["projects", "skills", "agents", "commands", "plugins", "hooks", "themes", "output-styles", "file-history", "todos", "plans"]
            files = ["CLAUDE.md", "history.jsonl", "keybindings.json"]
        case "codex":
            directories = ["sessions", "archived_sessions", "prompts", "skills", "rules", "plugins"]
            files = ["AGENTS.md", "history.jsonl", "hooks.json"]
        default:
            directories = ["sessions", "skills", "agents", "plugins", "installed-plugins", "marketplace-cache", "hooks", "memory", "memory-v2", "rules", "commands", "workflows", "personas", "worktrees"]
            // Upstream shares these whole. config.toml/settings.json are projected without credential keys
            // instead; worktrees.db stays per account like other SQLite state.
            files = ["lsp.json", "pager.toml", "sandbox.toml", "trusted_folders.toml", "statusline.sh"]
        }
        // Existing files and dangling links are never replaced; absent primary directories stay absent.
        for name in directories + files {
            let source = primary.appendingPathComponent(name), link = target.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path),
                  (try? FileManager.default.attributesOfItem(atPath: link.path)) == nil else { continue }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        }
        try projectSettings(provider, primary: primary, target: target, refresh: false)
    }
    private func projectSettings(_ provider: Provider, primary: URL, target: URL, refresh: Bool) throws {
        var env = resolver.childEnvironment
        env["HOME"] = store.paths.home.path
        env.removeValue(forKey: "PYTHONPATH"); env.removeValue(forKey: "PYTHONHOME"); env["PYTHONDONTWRITEBYTECODE"] = "1"
        let args = ["-B", runtime.root.appendingPathComponent("project-settings.py").path] + (refresh ? ["--refresh"] : []) + [provider.id, primary.path, target.path]
        let result = try ChildProcess.run(runtime.python, args, environment: env, timeout: 15)
        guard result.status == 0 else { throw DeckError.message("Could not project account settings; primary files preserved") }
    }
    /// Secondary settings are a snapshot taken at creation. This re-applies the primary's general
    /// settings (MCP, hooks, plugins, preferences) to one account, keeping the account's own sign-in
    /// state. The account's previous file is saved beside it as `.previous`.
    public func resyncSettings(_ provider: Provider, id: String) throws {
        let registry = try registry(provider)
        guard let account = registry.accounts.first(where: { $0.id == id }) else { throw DeckError.message("Unknown account") }
        guard !account.primary else { throw DeckError.message("The primary account is the source of shared settings") }
        try prepareHome(provider, account: account)
        try projectSettings(provider, primary: store.paths.home.appendingPathComponent("." + provider.id), target: URL(fileURLWithPath: account.home), refresh: true)
    }
    public func rename(_ provider: Provider, id: String, label: String) throws {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.count <= 80 else { throw DeckError.message("Invalid account name") }
        try update(provider) { registry in
            guard let i = registry.accounts.firstIndex(where: { $0.id == id }) else { throw DeckError.message("Unknown account") }
            registry.accounts[i].label = label
        }
    }
    public func remove(_ provider: Provider, id: String) throws {
        try update(provider) { registry in
            guard let account = registry.accounts.first(where: { $0.id == id }), !account.primary else { throw DeckError.message("The existing primary account is preserved") }
            registry.accounts.removeAll { $0.id == id }
            if registry.active == id { registry.active = registry.accounts.first!.id }
            registry.alert = ""
            // Keep the home and Keychain item for sessions already using it. `recover` can reattach it.
            let retired = store.paths.accounts.appendingPathComponent("retired-\(provider.id)-\(id).json")
            try store.write(account, to: retired)
        }
    }
    public func recover(_ provider: Provider, id: String) throws {
        let retired = store.paths.accounts.appendingPathComponent("retired-\(provider.id)-\(id).json")
        let account = try JSONDecoder().decode(Account.self, from: Data(contentsOf: retired))
        try update(provider) { registry in
            guard !registry.accounts.contains(where: { $0.id == account.id }) else { return }
            registry.accounts.append(account)
        }
    }
    public func use(_ provider: Provider, id: String) throws {
        try update(provider) { registry in
            let target: Account?
            if id == "next", let i = registry.accounts.firstIndex(where: { $0.id == registry.active }) {
                let eligible = Array(registry.accounts[(i + 1)...]) + Array(registry.accounts[...i])
                target = eligible.first { !$0.pendingLogin }
            } else { target = registry.accounts.first { $0.id == id } }
            guard let account = target, !account.pendingLogin else { throw DeckError.message("Unknown account or login not completed") }
            registry.active = account.id; registry.alert = ""; registry.lastSwitchAt = Date().timeIntervalSince1970
        }
    }
    public func setMode(_ provider: Provider, auto: Bool, threshold: Int) throws {
        guard (50...100).contains(threshold) else { throw DeckError.message("Threshold must be between 50 and 100") }
        try update(provider) { $0.switch = auto ? "auto" : "manual"; $0.threshold = threshold; $0.alert = "" }
    }
    public func finishLogin(_ provider: Provider, id: String) throws {
        try update(provider) { registry in
            guard let i = registry.accounts.firstIndex(where: { $0.id == id }) else { throw DeckError.message("Unknown account") }
            registry.accounts[i].pendingLogin = false
        }
    }
    public func launchEnvironment(_ provider: Provider, accountID: String? = nil,
                                  base: [String: String]? = nil, forLogin: Bool = false) throws -> [String: String] {
        var env = base ?? resolver.childEnvironment
        guard let variable = provider.homeVariable else { return env }
        // Explicit user homes win over the registry. A UI selection/--account is an explicit selection too.
        if !forLogin, accountID == nil, !(env[variable] ?? "").isEmpty { return env }
        let registry = try registry(provider)
        let id = accountID ?? registry.active
        guard let account = registry.accounts.first(where: { $0.id == id }) else { throw DeckError.message("Unknown account") }
        if !forLogin, account.pendingLogin { throw DeckError.message("Complete this account's login first") }
        try prepareHome(provider, account: account)
        // Leave primary's default Keychain namespace unchanged. Explicit secondary homes get their own namespace.
        if account.primary {
            env.removeValue(forKey: variable)
            if provider.id == "claude", accountID != nil || forLogin { env.removeValue(forKey: "CLAUDE_SECURESTORAGE_CONFIG_DIR") }
        } else {
            env[variable] = account.home
            if provider.id == "claude" { env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = account.home }
        }
        // Exported credentials must not silently authenticate a selected different account.
        if !account.primary || forLogin || accountID != nil {
            let keys: [String]
            switch provider.id {
            case "claude": keys = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR"]
            case "codex": keys = ["CODEX_ACCESS_TOKEN", "OPENAI_API_KEY", "CODEX_API_KEY"]
            default: keys = ["GROK_API_KEY", "XAI_API_KEY", "GROK_ACCESS_TOKEN"]
            }
            for key in keys { env.removeValue(forKey: key) }
        }
        return env
    }
}
