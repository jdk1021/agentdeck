import Foundation
import Darwin
import Security
import LocalAuthentication

public enum ShellQuote {
    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
}

public enum ProviderSecrets {
    public static let variables: [String: String] = ["claude":"ANTHROPIC_API_KEY", "grok":"XAI_API_KEY", "kimi":"KIMI_API_KEY",
        "cursor":"CURSOR_AUTH_TOKEN", "copilot":"GH_TOKEN", "kimchi":"KIMCHI_API_KEY", "devin":"DEVIN_API_KEY", "vibe":"MISTRAL_API_KEY",
        "zai":"ZAI_API_KEY", "ollama":"OLLAMA_API_KEY", "minimax":"MINIMAX_API_KEY", "openrouter":"OPENROUTER_API_KEY",
        "deepseek":"DEEPSEEK_API_KEY", "fireworks":"FIREWORKS_API_KEY", "synthetic":"SYNTHETIC_API_KEY"]
    private static let service = "org.agentdeck.provider-credentials"
    public static func set(provider: String, secret: String) throws {
        guard variables[provider] != nil else { throw DeckError.message("This provider uses its own CLI login") }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: provider]
        if secret.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw DeckError.message("Cannot remove Keychain item (\(status))") }
            return
        }
        let update = [kSecValueData as String: Data(secret.utf8)]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(update) { _, new in new }.merging([kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw DeckError.message("Cannot save Keychain item (\(status))") }
    }
    public static func environment(_ base: [String: String]) -> [String: String] {
        if base["AGENTDECK_FIXTURE_MODE"] == "1" { return base }
        var env = base
        for (provider, variable) in variables where (env[variable] ?? "").isEmpty {
            let context = LAContext(); context.interactionNotAllowed = true
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: provider, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationContext as String: context]
            var result: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
               let data = result as? Data, let secret = String(data: data, encoding: .utf8) { env[variable] = secret }
        }
        return env
    }
}

public struct ShellIntegration {
    public let store: DiskStore
    public init(store: DiskStore) { self.store = store }
    private let start = "# >>> AgentDeck managed integration >>>"
    private let end = "# <<< AgentDeck managed integration <<<"
    public var shellFile: URL { store.paths.root.appendingPathComponent("shell.zsh") }
    public func install(cli: URL, rcFile: URL? = nil) throws {
        let rc = (rcFile ?? store.paths.home.appendingPathComponent(".zshrc")).resolvingSymlinksInPath()
        var lines = ["# AGENTDECK_WRAPPER: reversible shell functions; binaries and mise shims are unchanged."]
        for provider in ["claude", "codex", "grok"] {
            lines.append("function \(provider)() { command \(ShellQuote.quote(cli.path)) run \(provider) -- \"$@\"; }")
        }
        lines.append("function agentdeck() { command \(ShellQuote.quote(cli.path)) \"$@\"; }")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: shellFile, options: .atomic)
        try edit(rc: rc, install: true)
    }
    public func uninstall(rcFile: URL? = nil) throws { try edit(rc: (rcFile ?? store.paths.home.appendingPathComponent(".zshrc")).resolvingSymlinksInPath(), install: false) }
    private func edit(rc: URL, install: Bool) throws {
        try store.locked(rc) {
            let text = try FileManager.default.fileExists(atPath: rc.path) ? String(contentsOf: rc, encoding: .utf8) : ""
            let mode = (try? FileManager.default.attributesOfItem(atPath: rc.path)[.posixPermissions] as? Int) ?? 0o600
            var new = text
            if let lo = new.range(of: start) {
                guard let hi = new.range(of: end, range: lo.upperBound..<new.endIndex) else { throw DeckError.message("Incomplete AgentDeck marker; original shell file preserved") }
                var upper = hi.upperBound
                if upper < new.endIndex, new[upper] == "\n" { upper = new.index(after: upper) }
                new.removeSubrange(lo.lowerBound..<upper)
            }
            if install {
                if !new.isEmpty && !new.hasSuffix("\n") { new += "\n" }
                new += "\(start)\nsource \(ShellQuote.quote(shellFile.path))\n\(end)\n"
            }
            if text == new { return }
            let backups = store.paths.root.appendingPathComponent("backups")
            try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let backup = backups.appendingPathComponent("zshrc-\(UUID().uuidString).txt")
            try Data(text.utf8).write(to: backup, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            try Data(new.utf8).write(to: rc, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: rc.path)
        }
    }
}

public enum SessionLauncher {
    public static func execute(binary: URL, arguments: [String], environment: [String: String]) throws -> Never {
        let depth = Int(environment["AGENTDECK_LAUNCH_DEPTH"] ?? "0") ?? 0
        guard depth < 2 else { throw DeckError.message("Wrapper recursion detected; remove duplicate wrappers from PATH") }
        var env = environment; env["AGENTDECK_LAUNCH_DEPTH"] = String(depth + 1)
        let args = ([binary.path] + arguments).map { strdup($0) } + [nil]
        let vars = env.sorted(by: { $0.key < $1.key }).map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { args.forEach { free($0) }; vars.forEach { free($0) } }
        execve(binary.path, args, vars)
        throw DeckError.message("Could not launch \(binary.lastPathComponent): \(String(cString: strerror(errno)))")
    }
    /// Runs an interactive program (a provider's sign-in) attached to this terminal and waits for it.
    /// It stays in the caller's foreground process group with inherited stdin/stdout/stderr, so it can
    /// read the keyboard. (Foundation's Process moves children out of the foreground group, which makes
    /// the terminal stop them with SIGTTIN/SIGTTOU as soon as they read input.)
    public static func runInteractive(binary: URL, arguments: [String], environment: [String: String]) throws -> Int32 {
        let args = ([binary.path] + arguments).map { strdup($0) } + [nil]
        let vars = environment.sorted(by: { $0.key < $1.key }).map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { args.forEach { free($0) }; vars.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, binary.path, nil, nil, args, vars)
        guard spawned == 0 else { throw DeckError.message("Could not launch \(binary.lastPathComponent): \(String(cString: strerror(spawned)))") }
        // The sign-in owns Ctrl-C while it runs; this process only waits for its result.
        let previous = signal(SIGINT, SIG_IGN)
        defer { signal(SIGINT, previous) }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        return (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }
    /// AppleScript that closes the Terminal window owning a given tty (passed as the first argument).
    static let closeWindowScript = ["on run argv", "tell application \"Terminal\"", "repeat with w in windows",
                                    "repeat with t in tabs of w", "if tty of t is item 1 of argv then close w",
                                    "end repeat", "end repeat", "end tell", "end run"]

    /// A Terminal `.command` file that runs the CLI and removes itself. With `closeOnSuccess`, the window
    /// closes by itself once the command succeeds (for sign-ins); on failure it stays open so the error
    /// can be read. The close runs detached, after the shell has exited, so Terminal never asks to
    /// terminate a running process.
    public static func commandFile(cli: URL, arguments: [String], directory: URL, store: DiskStore, closeOnSuccess: Bool = false) throws -> URL {
        let folder = store.paths.root.appendingPathComponent("launches")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent(UUID().uuidString + ".command")
        var script = "#!/bin/zsh\ndeck_tty=$(/usr/bin/tty)\ncd \(ShellQuote.quote(directory.path)) || exit 1\n"
            + ([cli.path] + arguments).map(ShellQuote.quote).joined(separator: " ")
            + "\ndeck_status=$?\n/bin/rm -f -- \(ShellQuote.quote(file.path))\n"
        if closeOnSuccess {
            let osa = closeWindowScript.map { "-e " + ShellQuote.quote($0) }.joined(separator: " ")
            script += "if [ $deck_status -eq 0 ]; then\n  ( /bin/sleep 0.7; /usr/bin/osascript \(osa) \"$deck_tty\" ) >/dev/null 2>&1 &!\nfi\n"
        }
        script += "exit $deck_status\n"
        try Data(script.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
}
