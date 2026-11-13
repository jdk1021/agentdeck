import Foundation

public struct RefreshResult: Sendable {
    public var records: [UsageRecord]
    public var events: [DeckEvent]
}
public struct DeckEvent: Identifiable, Sendable {
    public let id = UUID()
    public var title: String
    public var body: String
}

public actor CollectorService {
    public let store: DiskStore
    public let runtime: CollectorRuntime
    public let providers: [Provider]
    public let resolver: CLIResolver
    private var refreshing = false
    public init(store: DiskStore, runtime: CollectorRuntime, resolver: CLIResolver = CLIResolver()) throws {
        self.store = store; self.runtime = runtime; self.resolver = resolver
        providers = try Provider.load(from: runtime.root)
    }
    public func refresh(force: Bool = false, limitsOnly: Bool = false, only: Set<String>? = nil) async throws -> RefreshResult {
        guard !refreshing else { return RefreshResult(records: try store.records(), events: []) }
        refreshing = true; defer { refreshing = false }
        let settings = try store.settings()
        let chosen = providers.filter { !settings.disabledProviders.contains($0.id) && (only == nil || only!.contains($0.id)) }
        let store = self.store, runtime = self.runtime, resolver = self.resolver
        let refreshStamp = String(Int(Date().timeIntervalSince1970 * 1000))
        // Bound concurrency: local indexes are shared under flock, and each RPC can run a CLI.
        await withTaskGroup(of: Void.self) { group in
            var iterator = chosen.makeIterator()
            for _ in 0..<min(4, chosen.count) {
                if let provider = iterator.next() { group.addTask { Self.collect(provider, store: store, runtime: runtime, resolver: resolver, force: force, limitsOnly: limitsOnly, stamp: refreshStamp) } }
            }
            while await group.next() != nil {
                if let provider = iterator.next() { group.addTask { Self.collect(provider, store: store, runtime: runtime, resolver: resolver, force: force, limitsOnly: limitsOnly, stamp: refreshStamp) } }
            }
        }
        var events: [DeckEvent] = []
        var records = try store.records()
        let accounts = AccountManager(store: store, runtime: runtime, resolver: resolver)
        for provider in providers where provider.supportsAccounts {
            guard let record = records.first(where: { $0.id == provider.id }) else { continue }
            try accounts.update(provider) { registry in
                guard let decision = SwitchPolicy.decide(registry: registry, record: record) else { return }
                registry.alert = decision.alert
                switch decision.action {
                case .clear: break
                case .switched:
                    guard let id = decision.target, let target = registry.accounts.first(where: { $0.id == id }) else { return }
                    registry.active = id; registry.lastSwitchAt = Date().timeIntervalSince1970
                    events.append(DeckEvent(title: "\(provider.name): account switched", body: "New sessions use \(target.label). Running sessions keep their account."))
                case .suggest:
                    let label = registry.accounts.first { $0.id == decision.target }?.label ?? "another account"
                    events.append(DeckEvent(title: "\(provider.name) reached \(registry.threshold)%", body: "\(label) has available capacity. Switch in AgentDeck."))
                case .exhausted:
                    let reset = decision.nextReset.map { " Next available reset: \($0.formatted())." } ?? " Reset time is unavailable."
                    events.append(DeckEvent(title: "All \(provider.name) accounts reached \(registry.threshold)%", body: "Keeping the current account." + reset))
                }
            }
        }
        // Account activity is read from the registry, avoiding a second paid/rate-limited probe after a switch.
        records = try store.records()
        if !settings.syncDirectory.isEmpty { try UsageSync(store: store).export(records: records, settings: settings) }
        return RefreshResult(records: records, events: events)
    }
    private nonisolated static func collect(_ provider: Provider, store: DiskStore, runtime: CollectorRuntime,
                                           resolver: CLIResolver, force: Bool, limitsOnly: Bool, stamp: String) {
        let file = store.paths.usage.appendingPathComponent(provider.id + ".json")
        do {
            try store.locked(file) {
                var env = runtime.environment(store: store, resolver: resolver)
                env["AGENTDECK_REFRESH_AT"] = stamp
                let rg = runtime.root.appendingPathComponent("tools")
                env["PATH"] = rg.path + ":" + (env["PATH"] ?? "")
                // -B: never write bytecode into the signed app bundle.
                var args = ["-B", runtime.root.appendingPathComponent("bin/agentdeck-collect-" + provider.id).path]
                if force { args.append("--force") }; if limitsOnly { args.append("--limits-only") }
                let answer = try ChildProcess.run(runtime.python, args, environment: env, timeout: 110)
                guard answer.status == 0, answer.stdout.count < 16_000_000 else { throw DeckError.message("Collector exited with status \(answer.status)") }
                let record = try UsageRecord(data: answer.stdout)
                guard record.id == provider.id else { throw DeckError.message("Collector identity mismatch") }
                try store.write(record.raw, to: file, backup: false)
            }
        } catch {
            // Preserve measured values and their timestamps. A failed process is never zero usage.
            try? store.locked(file) {
                var object = ((try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) })?.object ?? [
                    "schemaVersion": .number(1), "id": .string(provider.id), "name": .string(provider.name), "ready": .bool(false)
                ]
                object["collectorFailed"] = .bool(true); object["limitsStale"] = .bool(true)
                object["usageStatusText"] = .string("Collection failed; retained last measured data")
                object["lastAttemptAt"] = .string(ISO8601DateFormatter().string(from: Date()))
                try store.write(JSONValue.object(object), to: file, backup: false)
            }
        }
    }
}

public enum RefreshSchedule {
    public static func next(settings: DeckSettings, records: [UsageRecord], registries: [String: AccountRegistry]) -> (seconds: Int, limitsOnly: Bool, retry: Set<String>?) {
        let retry = Set(records.filter { $0.raw["retryAdvised"].bool }.map(\.id))
        if !retry.isEmpty { return (30, true, retry) }
        let near = records.contains { record in
            guard let registry = registries[record.id], registry.accounts.count > 1 else { return false }
            return (record.peak ?? 0) >= min(0.8, Double(registry.threshold - 15) / 100)
        }
        return (near ? min(180, settings.refreshInterval) : settings.refreshInterval, near, nil)
    }

    public struct Step: Equatable, Sendable {
        public var seconds: Int
        public var limitsOnly: Bool
        public var only: Set<String>?
        public init(seconds: Int, limitsOnly: Bool, only: Set<String>?) { self.seconds = seconds; self.limitsOnly = limitsOnly; self.only = only }
    }
    /// Exactly one refresh per wake-up. Short limits-only passes (retry/near threshold) never replace the
    /// regular full refresh: once the regular interval has elapsed since the last full pass, the next
    /// wake-up is a full one, so statistics keep updating and no second refresh follows a short pass.
    public static func step(settings: DeckSettings, records: [UsageRecord], registries: [String: AccountRegistry],
                            lastFull: Date, now: Date = Date()) -> Step {
        let base = next(settings: settings, records: records, registries: registries)
        let untilFull = max(0, Int(ceil(lastFull.addingTimeInterval(TimeInterval(settings.refreshInterval)).timeIntervalSince(now))))
        if !base.limitsOnly || untilFull <= base.seconds { return Step(seconds: untilFull == 0 ? 1 : untilFull, limitsOnly: false, only: nil) }
        return Step(seconds: base.seconds, limitsOnly: true, only: base.retry)
    }
}
