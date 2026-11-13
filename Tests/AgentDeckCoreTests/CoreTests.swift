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
}
