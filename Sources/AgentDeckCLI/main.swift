import Foundation
import AgentDeckCore
import Darwin

@main
struct AgentDeckCLI {
    static func main() async {
        do { try await run(Array(CommandLine.arguments.dropFirst())) }
        catch { FileHandle.standardError.write(Data(("agentdeck: \(error.localizedDescription)\n").utf8)); exit(1) }
    }
    static let help = """
    AgentDeck — macOS agent usage and isolated accounts
    agentdeck providers
    agentdeck status [--json]
    agentdeck refresh [--force] [--limits-only] [provider ...]
    agentdeck account list <provider>
    agentdeck account add <provider> <label>
    agentdeck account login <provider> <id>
    agentdeck account use <provider> <id|next>
    agentdeck account rename <provider> <id> <label>
    agentdeck account remove|recover <provider> <id>
    agentdeck account mode <provider> <auto|manual> [50...100]
    agentdeck account sync-settings <provider> <id>
    agentdeck login <provider>
    agentdeck run <provider> [--account <id>] -- [CLI arguments ...]
    agentdeck settings [refresh <seconds>|sync <directory|off>]
    agentdeck shell install|uninstall
    agentdeck diagnostics
    agentdeck restore <settings|claude|codex|grok>
    agentdeck sync
    agentdeck watch
    agentdeck uninstall

    uninstall removes shell integration; account homes, Keychain items and histories are retained.
    """
    static func run(_ args: [String]) async throws {
        guard let command = args.first, command != "help", command != "--help", command != "-h" else { print(help); return }
        let store = try DiskStore(), resolver = CLIResolver(), runtime = try CollectorRuntime(resolver: resolver)
        let providers = try Provider.load(from: runtime.root)
        let manager = AccountManager(store: store, runtime: runtime, resolver: resolver)
        func provider(_ id: String?) throws -> Provider {
            guard let provider = providers.first(where: { $0.id == id }) else { throw DeckError.message("Unknown provider; run agentdeck providers") }
            return provider
        }
        func item(_ index: Int) throws -> String {
            guard args.indices.contains(index) else { throw DeckError.message(help) }; return args[index]
        }
        func printJSON<T: Encodable>(_ object: T) throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(object), as: UTF8.self))
        }
        switch command {
        case "providers":
            for p in providers { print("\(p.id)\t\(p.name)\t\(p.supportsAccounts ? "usage + accounts" : "usage")") }
        case "status":
            let records = try store.records().sorted { $0.name < $1.name }
            if args.contains("--json") { try printJSON(records.map(\.raw)) }
            else {
                for record in records {
                    let level = record.peak.map { String(format: "%.0f%%", $0 * 100) } ?? "no reported limit"
                    print("\(record.id)\t\(record.plan)\t\(level)\(record.isStale ? " [stale]" : "")\t\(record.status)")
                }
                if records.isEmpty { print("No cached usage. Run agentdeck refresh.") }
            }
        case "refresh":
            let ids = Set(args.dropFirst().filter { !$0.hasPrefix("--") })
            if !ids.isSubset(of: Set(providers.map(\.id))) { throw DeckError.message("Unknown collector") }
            let service = try CollectorService(store: store, runtime: runtime, resolver: resolver)
            let result = try await service.refresh(force: args.contains("--force"), limitsOnly: args.contains("--limits-only"), only: ids.isEmpty ? nil : ids)
            for event in result.events { print("\(event.title): \(event.body)") }
            print("Collected \(result.records.count) provider records")
            if result.records.contains(where: { $0.raw["collectorFailed"].bool && (ids.isEmpty || ids.contains($0.id)) }) { throw DeckError.message("One or more collectors failed; retained last data. See status --json.") }
        case "account":
            let action = try item(1), p = try provider(item(2))
            switch action {
            case "list": try printJSON(manager.registry(p))
            case "add":
                let account = try manager.add(p, label: args.dropFirst(3).joined(separator: " "))
                print("Created \(account.id). Complete login: agentdeck account login \(p.id) \(account.id)")
            case "login":
                let id = try item(3), env = try manager.launchEnvironment(p, accountID: id, forLogin: true)
                try login(provider: p, env: env, resolver: resolver)
                try manager.finishLogin(p, id: id)
                print("Login completed. Use agentdeck account use \(p.id) \(id) for new sessions.")
            case "use": try manager.use(p, id: item(3)); print("New \(p.name) sessions use the selected account.")
            case "rename": try manager.rename(p, id: item(3), label: args.dropFirst(4).joined(separator: " "))
            case "remove": try manager.remove(p, id: item(3)); print("Removed from registry; running sessions and account files retained.")
            case "recover": try manager.recover(p, id: item(3))
            case "sync-settings":
                try manager.resyncSettings(p, id: item(3))
                print("Re-applied the primary's general settings. Sign-in state kept; previous files saved as .previous.")
            case "mode":
                let mode = try item(3); guard ["auto", "manual"].contains(mode) else { throw DeckError.message("Expected auto or manual") }
                let threshold = args.count > 4 ? Int(args[4]) : 95
                guard let threshold else { throw DeckError.message("Invalid threshold") }
                try manager.setMode(p, auto: mode == "auto", threshold: threshold)
            default: throw DeckError.message(help)
            }
        case "run":
            let p = try provider(item(1))
            guard let executable = p.executable else { throw DeckError.message("Launch this billing provider through pi, omp, or opencode; it has no standalone agent CLI") }
            var id: String?, passed: [String] = [], i = 2
            while i < args.count {
                if args[i] == "--" { passed = Array(args.dropFirst(i + 1)); break }
                if args[i] == "--account", i + 1 < args.count { id = args[i + 1]; i += 2 }
                else { throw DeckError.message("Place agent arguments after --") }
            }
            let env = p.supportsAccounts ? try manager.launchEnvironment(p, accountID: id) : ProviderSecrets.environment(resolver.childEnvironment)
            try SessionLauncher.execute(binary: resolver.find(executable), arguments: passed, environment: env)
        case "login":
            let p = try provider(item(1))
            try login(provider: p, env: resolver.childEnvironment, resolver: resolver)
        case "settings":
            var s = try store.settings()
            if args.count == 1 { try printJSON(s); return }
            switch try item(1) {
            case "refresh": guard let n = Int(try item(2)), (30...3600).contains(n) else { throw DeckError.message("Expected 30...3600 seconds") }; s.refreshInterval = n
            case "sync": let path = try item(2); s.syncDirectory = path == "off" ? "" : URL(fileURLWithPath: path).standardizedFileURL.path
            default: throw DeckError.message(help)
            }
            try store.saveSettings(s)
        case "shell":
            let integration = ShellIntegration(store: store)
            if try item(1) == "install" { try integration.install(cli: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()) }
            else if try item(1) == "uninstall" { try integration.uninstall() }
            else { throw DeckError.message(help) }
            print("Shell integration updated. Open a new zsh session. Backups are in AgentDeck/backups.")
        case "diagnostics":
            print("AgentDeck \(AgentDeckVersion.current) • macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
            print("Runtime: \(runtime.root.path)\nPython: \(runtime.python.path)\nCollectors: \(providers.count)")
            for name in ["mise", "claude", "codex", "grok"] { print("\(name): \((try? resolver.find(name).path) ?? "not installed")") }
            print("Cached providers: \(try store.records().count). No credentials or transcript contents included.")
        case "restore":
            let name = try item(1)
            let file = name == "settings" ? store.settingsURL : manager.registryURL(try provider(name))
            try store.restore(file); print("Restored previous complete state.")
        case "sync":
            let sync = UsageSync(store: store), settings = try store.settings(), records = try store.records()
            guard !settings.syncDirectory.isEmpty else { throw DeckError.message("Configure a sync folder in Settings first") }
            try sync.export(records: records, settings: settings); try printJSON(sync.aggregate(settings: settings, records: records))
        case "watch":
            let service = try CollectorService(store: store, runtime: runtime, resolver: resolver)
            var step = RefreshSchedule.Step(seconds: 0, limitsOnly: false, only: nil)
            var lastFull = Date.distantPast
            while true {
                let result = try await service.refresh(limitsOnly: step.limitsOnly, only: step.only)
                if !step.limitsOnly { lastFull = Date() }
                for event in result.events { print("\(event.title): \(event.body)") }
                let settings = try store.settings()
                let registries = Dictionary(uniqueKeysWithValues: try providers.filter(\.supportsAccounts).map { ($0.id, try manager.registry($0)) })
                step = RefreshSchedule.step(settings: settings, records: result.records, registries: registries, lastFull: lastFull)
                try await Task.sleep(for: .seconds(step.seconds))
            }
        case "uninstall":
            try ShellIntegration(store: store).uninstall()
            print("Shell integration removed. Disable Launch at Login in the app, quit it, then delete AgentDeck.app. App state and all agent data are retained. See docs/installation.md for optional cleanup.")
        default: throw DeckError.message(help)
        }
    }
    static func login(provider: Provider, env: [String: String], resolver: CLIResolver) throws {
        guard let name = provider.executable else { throw DeckError.message("Set this provider's key in the app's Keychain settings or log in through pi/omp/opencode") }
        let status = try SessionLauncher.runInteractive(binary: resolver.find(name), arguments: provider.loginArguments, environment: env)
        guard status == 0 else { throw DeckError.message("Login did not complete. Existing credentials were preserved.") }
    }
}
