import Foundation

public struct SwitchDecision: Equatable, Sendable {
    public enum Action: String, Sendable { case clear, suggest, switched, exhausted }
    public var action: Action
    public var target: String?
    public var alert: String
    public var nextReset: Date?
    public init(action: Action, target: String? = nil, alert: String = "", nextReset: Date? = nil) {
        self.action = action; self.target = target; self.alert = alert; self.nextReset = nextReset
    }
}

public enum SwitchPolicy {
    /// Upstream's headroom/freshness/peak/reset ordering, with conservative stale exclusion and cooldown.
    public static func decide(registry: AccountRegistry, record: UsageRecord, now: Date = Date()) -> SwitchDecision? {
        guard registry.accounts.count > 1 else { return nil }
        let entries = record.accounts
        let threshold = Double(registry.threshold) / 100
        func entry(_ id: String) -> JSONValue? { entries.first { $0["id"].string == id } }
        func validLimits(_ account: Account) -> [UsageLimit]? {
            guard !account.pendingLogin, !record.isStale,
                  let e = entry(account.id), !e["stale"].bool,
                  e["usageStatusText"].string.isEmpty,
                  let stamp = e["fetchedAt"].double ?? record.raw["limitsFetchedAt"].double,
                  stamp > 0, now.timeIntervalSince1970 - stamp / 1000 < 1800 else { return nil }
            let limits = e["limits"].array.compactMap(UsageLimit.init)
            return limits.isEmpty ? nil : limits
        }
        guard let current = registry.accounts.first(where: { $0.id == registry.active }),
              let limits = validLimits(current), let peak = limits.map({ $0.level(at: now) }).max() else { return nil }
        if peak < threshold { return registry.alert.isEmpty ? nil : SwitchDecision(action: .clear) }
        // Avoid oscillation caused by concurrent refreshes and windows reported on different clocks.
        guard now.timeIntervalSince1970 - registry.lastSwitchAt >= 180 else { return nil }
        let candidates = registry.accounts.compactMap { account -> (Account, Double, Date)? in
            guard account.id != current.id, let limits = validLimits(account),
                  let level = limits.map({ $0.level(at: now) }).max(), level < threshold else { return nil }
            let reset = limits.compactMap(\.resetsAt).filter { $0 > now }.min() ?? .distantFuture
            return (account, level, reset)
        }.sorted {
            let near0 = $0.1 >= threshold - 0.15, near1 = $1.1 >= threshold - 0.15
            if near0 != near1 { return !near0 }
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            if $0.2 != $1.2 { return $0.2 < $1.2 }
            return $0.0.id < $1.0.id
        }
        if let target = candidates.first {
            let action: SwitchDecision.Action = registry.switch == "auto" ? .switched : .suggest
            let alert = "\(action.rawValue):\(current.id):\(target.0.id)"
            return registry.alert == alert ? nil : SwitchDecision(action: action, target: target.0.id, alert: alert)
        }
        guard registry.accounts.allSatisfy({ validLimits($0) != nil }) else { return nil }
        let alert = "exhausted:\(current.id)"
        guard registry.alert != alert else { return nil }
        let resets = registry.accounts.compactMap { account -> Date? in
            let blocked = (validLimits(account) ?? []).filter { $0.level(at: now) >= threshold }
            guard !blocked.isEmpty, blocked.allSatisfy({ $0.resetsAt != nil }) else { return nil }
            return blocked.compactMap(\.resetsAt).max()
        }
        return SwitchDecision(action: .exhausted, alert: alert, nextReset: resets.min())
    }
}
