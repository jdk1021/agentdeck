import XCTest
@testable import AgentDeckCore

final class CoreTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func temp() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentDeck tests \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func registry(mode: String = "auto") -> AccountRegistry {
        var r = AccountRegistry(); r.switch = mode
        r.accounts = [Account(id: "a", label: "A", home: "/a", pendingLogin: false), Account(id: "b", label: "B", home: "/b", pendingLogin: false), Account(id: "c", label: "C", home: "/c", pendingLogin: false)]
        r.active = "a"; return r
    }
    func testEmailIsTheAccountNameAndLabelIsAnOptionalMemo() throws {
        let legacy = Data(#"{"id":"primary","label":"Primary","home":"/fixture","primary":true,"pendingLogin":false}"#.utf8)
        var account = try JSONDecoder().decode(Account.self, from: legacy)
        XCTAssertNil(account.email)
        XCTAssertEqual(account.memo, "")
        XCTAssertEqual(account.displayName, "Email unavailable")
        account.email = "person@example.invalid"
        account.label = "Work"
        XCTAssertEqual(account.displayName, "person@example.invalid")
        XCTAssertEqual(account.memo, "Work")
        XCTAssertEqual(account.menuTitle, "person@example.invalid · Work")
        account.label = ""
        XCTAssertEqual(account.menuTitle, "person@example.invalid")
    }

    func testClaudeIdentityFollowsTheAccountHomeAndUpdatedProfile() throws {
        let root = try temp(), primary = root.appendingPathComponent(".claude"), secondary = root.appendingPathComponent("secondary")
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondary, withIntermediateDirectories: true)
        let main = root.appendingPathComponent(".claude.json"), other = secondary.appendingPathComponent(".claude.json")
        try Data(#"{"oauthAccount":{"emailAddress":"primary@example.invalid"}}"#.utf8).write(to: main)
        try Data(#"{"oauthAccount":{"emailAddress":"secondary@example.invalid"}}"#.utf8).write(to: other)
        let a = Account(id: "primary", label: "Memo", home: primary.path, primary: true)
        let b = Account(id: "other", label: "Memo", home: secondary.path)
        XCTAssertEqual(AccountIdentity.email(provider: "claude", account: a, userHome: root), "primary@example.invalid")
        XCTAssertEqual(AccountIdentity.email(provider: "claude", account: b, userHome: root), "secondary@example.invalid")
        try Data(#"{"oauthAccount":{"emailAddress":"new@example.invalid"}}"#.utf8).write(to: other)
        XCTAssertEqual(AccountIdentity.email(provider: "claude", account: b, userHome: root), "new@example.invalid")
        try Data("{}".utf8).write(to: other)
        XCTAssertNil(AccountIdentity.email(provider: "claude", account: b, userHome: root))
    }

    func testCodexIdentityReadsOnlyEmailAndHonorsAPIKeyLogin() throws {
        let root = try temp(), auth = root.appendingPathComponent("auth.json")
        let account = Account(id: "a", label: "Memo", home: root.path)
        let claims = Data(#"{"email":"codex@example.invalid","private":"fixture-secret"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let token: JSONValue = .object(["id_token": .string("header.\(claims).signature")])
        func write(_ mode: String, _ key: String = "") throws {
            try JSONEncoder().encode(JSONValue.object(["auth_mode": .string(mode), "OPENAI_API_KEY": .string(key), "tokens": token])).write(to: auth)
        }
        try write("chatgpt")
        XCTAssertEqual(AccountIdentity.email(provider: "codex", account: account, userHome: root), "codex@example.invalid")
        try write("apikey", "fixture-secret")
        XCTAssertNil(AccountIdentity.email(provider: "codex", account: account, userHome: root))
        try write("", "fixture-secret")
        XCTAssertNil(AccountIdentity.email(provider: "codex", account: account, userHome: root))
        try write("chatgpt", "fixture-secret")
        XCTAssertEqual(AccountIdentity.email(provider: "codex", account: account, userHome: root), "codex@example.invalid")
        try Data(#"{"tokens":{"id_token":"malformed"}}"#.utf8).write(to: auth)
        XCTAssertNil(AccountIdentity.email(provider: "codex", account: account, userHome: root))
    }
    func record(levels: [String: Double], stale: Set<String> = [], reset: Date? = nil, fetched: Date? = nil, extra: [String: JSONValue] = [:]) throws -> UsageRecord {
        let rows: [JSONValue] = levels.map { id, n in
            .object(["id": .string(id), "limits": .array([.object(["label": .string("Weekly"), "percent": .number(n), "resetsAt": .string(ISO8601DateFormatter().string(from: reset ?? now.addingTimeInterval(86400)))])]),
                     "stale": .bool(stale.contains(id)), "fetchedAt": .number((fetched ?? now).timeIntervalSince1970 * 1000)])
        }
        let raw: [String: JSONValue] = ["schemaVersion": .number(1), "id": .string("claude"), "name": .string("Claude Code"), "accounts": .array(rows)]
        return try UsageRecord(raw: .object(raw.merging(extra, uniquingKeysWith: { _, new in new })))
    }
    func testSwitchAtDefaultThreshold() throws {
        let r = try record(levels: ["a": 0.95, "b": 0.4, "c": 0.7])
        let d = SwitchPolicy.decide(registry: registry(), record: r, now: now)
        XCTAssertEqual(d?.action, .switched); XCTAssertEqual(d?.target, "b")
        XCTAssertNil(SwitchPolicy.decide(registry: registry(), record: try record(levels: ["a": 0.949, "b": 0.4]), now: now))
    }
    func testProviderDisplayGroupsStayAheadOfUsageAndKeepAllProviders() throws {
        let root = try temp()
        let ids = ["deepseek", "claude", "kimi", "cursor", "minimax", "codex", "qwen", "grok", "zai"]
        let data = try JSONSerialization.data(withJSONObject: ["collectors": ids.map { ["id": $0, "name": $0] }])
        try data.write(to: root.appendingPathComponent("inventory.json"))
        let providers = try Provider.load(from: root)
        XCTAssertEqual(providers.count, ids.count)
        XCTAssertEqual(Set(providers.map(\.id)), Set(ids))
        XCTAssertEqual(Array(providers.prefix(4)).map(\.id), ["claude", "cursor", "codex", "grok"])
        // A nearly exhausted trailing provider still comes after an idle preferred provider.
        let levels = ["claude": 0.01, "grok": 0.2, "cursor": 0.3, "deepseek": 1.0, "qwen": 0.99]
        let ordered = levels.keys.sorted { lhs, rhs in
            ProviderDisplayOrder.precedes(lhs, rhs) { levels[lhs]! > levels[rhs]! }
        }
        XCTAssertEqual(ordered, ["cursor", "grok", "claude", "deepseek", "qwen"])
        XCTAssertFalse(ProviderDisplayOrder.isTrailingProvider("cursor"))
        XCTAssertFalse(ProviderDisplayOrder.isTrailingProvider("grok"))
        for model in ["deepseek-v3", "openrouter/qwen/qwen3", "moonshotai/kimi-k2", "z-ai/glm-4.6", "MiniMax-M2"] {
            XCTAssertTrue(ProviderDisplayOrder.isTrailingModel(model))
        }
        for model in ["grok-4", "claude-sonnet", "gpt-codex", "cursor-composer"] {
            XCTAssertFalse(ProviderDisplayOrder.isTrailingModel(model))
        }
    }
    func testManualSuggestsInsteadOfSwitching() throws {
        XCTAssertEqual(SwitchPolicy.decide(registry: registry(mode: "manual"), record: try record(levels: ["a": 0.99, "b": 0.1]), now: now)?.action, .suggest)
    }
    func testExhaustionKeepsCurrentAndReportsReset() throws {
        let d = SwitchPolicy.decide(registry: registry(), record: try record(levels: ["a": 1, "b": 0.95, "c": 1]), now: now)
        XCTAssertEqual(d?.action, .exhausted); XCTAssertNil(d?.target); XCTAssertEqual(d?.nextReset, now.addingTimeInterval(86400))
    }
    func testStaleAndUnknownAreNeverZero() throws {
        XCTAssertNil(SwitchPolicy.decide(registry: registry(), record: try record(levels: ["a": 1, "b": 0], stale: ["b"]), now: now))
        XCTAssertNil(SwitchPolicy.decide(registry: registry(), record: try record(levels: ["a": 1]), now: now))
        XCTAssertNil(SwitchPolicy.decide(registry: registry(), record: try record(levels: ["a": 1, "b": 0], fetched: now.addingTimeInterval(-1900)), now: now))
    }
    func testCooldownAndAlertDeduplication() throws {
        let record = try record(levels: ["a": 1, "b": 0])
        var registry = registry(); registry.lastSwitchAt = now.timeIntervalSince1970 - 40
        XCTAssertNil(SwitchPolicy.decide(registry: registry, record: record, now: now))
        registry.lastSwitchAt = 0; registry.alert = "switched:a:b"
        XCTAssertNil(SwitchPolicy.decide(registry: registry, record: record, now: now))
    }
    func testExpiredWindowDoesNotTriggerSwitch() throws {
        XCTAssertNil(SwitchPolicy.decide(registry: registry(), record: try record(levels: ["a": 1, "b": 1], reset: now.addingTimeInterval(-1)), now: now))
    }
    func testInvalidLimitsRejected() throws {
        for v: JSONValue in [.number(-1), .number(1.1), .bool(true), .string("0.5"), .null] {
            XCTAssertNil(UsageLimit(.object(["percent": v])))
        }
        XCTAssertThrowsError(try UsageRecord(data: Data("{}".utf8)))
    }
    func testAtomicStorageBackupAndRecovery() throws {
        let root = try temp(), store = try DiskStore(paths: DeckPaths(root: root))
        var s = DeckSettings(); s.refreshInterval = 120; try store.saveSettings(s)
        s.refreshInterval = 300; try store.saveSettings(s)
        try Data("{broken".utf8).write(to: store.settingsURL)
        XCTAssertThrowsError(try store.settings())
        try store.restore(store.settingsURL)
        XCTAssertEqual(try store.settings().refreshInterval, 120)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.settingsURL.path)[.posixPermissions] as? Int), 0o600)
    }
    func testConcurrentStateChangesAreSerialized() throws {
        let root = try temp(), store = try DiskStore(paths: DeckPaths(root: root)), file = root.appendingPathComponent("counter.json")
        try store.write(0, to: file)
        let queue = DispatchQueue(label: "concurrent", attributes: .concurrent), group = DispatchGroup()
        for _ in 0..<40 {
            group.enter(); queue.async {
                defer { group.leave() }
                try! store.locked(file) {
                    let n = try store.read(Int.self, at: file, fallback: 0); try store.write(n + 1, to: file)
                }
            }
        }
        group.wait(); XCTAssertEqual(try store.read(Int.self, at: file, fallback: 0), 40)
    }
    func testShellInstallMergeAndUninstallPreserveExistingContent() throws {
        let root = try temp(), store = try DiskStore(paths: DeckPaths(root: root.appendingPathComponent("app"), home: root)), rc = root.appendingPathComponent(".zshrc")
        let original = "# existing MCP setup\nexport PATH=\"$HOME/bin:$PATH\"\n# mise\neval \"$(mise activate zsh)\"\n"
        try Data(original.utf8).write(to: rc)
        let integration = ShellIntegration(store: store)
        let cli = root.appendingPathComponent("app with spaces/agentdeck")
        try integration.install(cli: cli, rcFile: rc); try integration.install(cli: cli, rcFile: rc)
        let installed = try String(contentsOf: rc)
        XCTAssertEqual(installed.components(separatedBy: "# >>> AgentDeck").count, 2)
        XCTAssertTrue(installed.hasPrefix(original))
        try integration.uninstall(rcFile: rc)
        XCTAssertEqual(try String(contentsOf: rc), original)
        XCTAssertFalse((try FileManager.default.contentsOfDirectory(atPath: store.paths.root.appendingPathComponent("backups").path)).isEmpty)
    }
    func testWrapperRecursionAndQuotedPaths() throws {
        let root = try temp(), fake = root.appendingPathComponent("claude")
        try Data("#!/bin/zsh\n# AGENTDECK_WRAPPER\n".utf8).write(to: fake); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let resolver = CLIResolver(environment: ["PATH": root.path], home: root)
        XCTAssertTrue(resolver.isWrapper(fake))
        let quoted = ShellQuote.quote("a b'$(touch /tmp/not-executed)")
        let answer = try ChildProcess.run(URL(fileURLWithPath: "/bin/zsh"), ["-c", "print -r -- " + quoted])
        XCTAssertEqual(String(decoding: answer.stdout, as: UTF8.self), "a b'$(touch /tmp/not-executed)\n")
    }
    func testBashInstallPreservesLoginProfilePrecedence() throws {
        for name in [".bash_profile", ".bash_login", ".profile"] {
            let root = try temp(), store = try DiskStore(paths: DeckPaths(root: root.appendingPathComponent("app"), home: root))
            let profile = root.appendingPathComponent(name), original = "# existing login setup\nexport KEEP_ME=1\n"
            try Data(original.utf8).write(to: profile)
            let integration = ShellIntegration(store: store)
            try integration.install(cli: root.appendingPathComponent("agentdeck"), shell: .bash)
            try integration.install(cli: root.appendingPathComponent("agentdeck"), shell: .bash)
            XCTAssertTrue(try String(contentsOf: profile).hasPrefix(original))
            XCTAssertEqual(try String(contentsOf: profile).components(separatedBy: "# >>> AgentDeck").count, 2)
            if name != ".bash_profile" { XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".bash_profile").path)) }
            if name == ".profile" {
                XCTAssertEqual(try ChildProcess.run(URL(fileURLWithPath: "/bin/sh"), [profile.path]).status, 0)
            }
            try integration.uninstall(shell: .bash)
            XCTAssertEqual(try String(contentsOf: profile), original)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".bashrc")), "")
        }
    }
    func testUninstallMissingShellDoesNotCreateStartupFiles() throws {
        let root = try temp(), store = try DiskStore(paths: DeckPaths(root: root.appendingPathComponent("app"), home: root))
        let integration = ShellIntegration(store: store)
        try integration.uninstall(shell: .bash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".bash_profile").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".bashrc").path))
    }
    func testLargeProcessOutputDoesNotDeadlock() throws {
        let r = try ChildProcess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "head -c 200000 /dev/zero; head -c 200000 /dev/zero >&2"], timeout: 10)
        XCTAssertEqual(r.stdout.count, 200000); XCTAssertEqual(r.stderr.count, 200000)
    }
    func testProcessTimeout() throws {
        XCTAssertThrowsError(try ChildProcess.run(URL(fileURLWithPath: "/bin/sleep"), ["2"], timeout: 0.05))
    }
    func testSyncProjectionExcludesSecretsAndIdentity() throws {
        let r = try record(levels: [:], extra: ["email": .string("fixture@example.invalid"), "accessToken": .string("fixture-secret"),
                                              "todayPrompts": .number(8), "modelUsage": .object(["example-model": .object(["inputTokens": .number(9), "token": .string("fixture-secret")])])])
        let data = try JSONEncoder().encode(UsageSync.projection(r)), text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("fixture-secret")); XCTAssertFalse(text.contains("email")); XCTAssertFalse(text.contains("accounts"))
        XCTAssertEqual(UsageSync.projection(r)["todayPrompts"].double, 8)
    }
    func testRefreshTiming() throws {
        var settings = DeckSettings()
        let r = try record(levels: [:], extra: ["retryAdvised": .bool(true)])
        XCTAssertEqual(RefreshSchedule.next(settings: settings, records: [r], registries: [:]).seconds, 30)
        settings.refreshInterval = 900
        let near = try record(levels: [:], extra: ["limits": .array([.object(["percent": .number(0.81), "label": .string("Weekly")])])])
        XCTAssertEqual(RefreshSchedule.next(settings: settings, records: [near], registries: ["claude": registry()]).seconds, 180)
        XCTAssertEqual(RefreshSchedule.next(settings: settings, records: [], registries: [:]).seconds, 900)
    }
    func testRefreshStepIssuesOneRefreshPerWake() throws {
        var settings = DeckSettings(); settings.refreshInterval = 900
        let now = Date()
        let near = try record(levels: [:], extra: ["limits": .array([.object(["percent": .number(0.81), "label": .string("Weekly")])])])
        // Near the threshold: short limits-only passes while the full interval has not elapsed.
        let short = RefreshSchedule.step(settings: settings, records: [near], registries: ["claude": registry()], lastFull: now, now: now)
        XCTAssertEqual(short, RefreshSchedule.Step(seconds: 180, limitsOnly: true, only: nil))
        // Once the full interval is due, the single wake-up is a full refresh (no extra pass).
        let due = RefreshSchedule.step(settings: settings, records: [near], registries: ["claude": registry()], lastFull: now.addingTimeInterval(-800), now: now)
        XCTAssertEqual(due, RefreshSchedule.Step(seconds: 100, limitsOnly: false, only: nil))
        let idle = RefreshSchedule.step(settings: settings, records: [], registries: [:], lastFull: now, now: now)
        XCTAssertEqual(idle, RefreshSchedule.Step(seconds: 900, limitsOnly: false, only: nil))
        let retry = try record(levels: [:], extra: ["retryAdvised": .bool(true)])
        XCTAssertEqual(RefreshSchedule.step(settings: settings, records: [retry], registries: [:], lastFull: now, now: now).only, ["claude"])
    }
    func testTimeoutTerminatesDescendantsOnly() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("agentdeck-pg-\(UUID().uuidString)")
        let started = Date()
        // The child starts a grandchild that would outlive it and write a marker; the group is terminated.
        XCTAssertThrowsError(try ChildProcess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "(sleep 1; touch '\(marker.path)') & sleep 5"], timeout: 0.3))
        XCTAssertTrue(Date().timeIntervalSince(started) < 3)
        Thread.sleep(forTimeInterval: 1.3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        // A detached descendant holding the output pipe does not block a finished command.
        let quick = Date()
        let result = try ChildProcess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo done; sleep 30 &"], timeout: 10)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "done\n")
        XCTAssertTrue(Date().timeIntervalSince(quick) < 5)
        XCTAssertEqual(try ChildProcess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "exit 3"]).status, 3)
    }
    /// Swift's cooperative pool threads block SIGWINCH; agents launched from there must still receive
    /// terminal resizes, otherwise they keep their startup width forever.
    func testLaunchedAgentsReceiveResizeSignalsFromBlockedThreads() throws {
        // Reproduce a pool thread's mask on this thread; the child exits 0 only if its WINCH trap runs.
        var block = sigset_t(), previous = sigset_t()
        sigemptyset(&block); sigaddset(&block, SIGWINCH)
        pthread_sigmask(SIG_BLOCK, &block, &previous)
        defer { pthread_sigmask(SIG_SETMASK, &previous, nil) }
        let script = "trap 'exit 0' WINCH; kill -WINCH $$; sleep 1; exit 1"
        let status = try SessionLauncher.runInteractive(binary: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                                                        environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(status, 0)
    }
}
