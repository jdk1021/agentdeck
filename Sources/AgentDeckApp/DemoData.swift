import Foundation
import AgentDeckCore

/// Synthetic data for screenshots and UI checks. Enabled with `--demo` or AGENTDECK_DEMO=1.
/// It uses a throwaway state folder, never runs collectors and never reads a real home or Keychain.
enum DemoData {
    static var enabled: Bool {
        CommandLine.arguments.contains("--demo") || ProcessInfo.processInfo.environment["AGENTDECK_DEMO"] == "1"
    }

    /// `--demo-arg value` style options used only for screenshots.
    static func option(_ name: String) -> String? {
        guard enabled, let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }

    static func makeStore(runtime: CollectorRuntime) throws -> DiskStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentDeck-demo-\(getpid())", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let store = try DiskStore(paths: DeckPaths(root: root.appendingPathComponent("state"), home: root.appendingPathComponent("home")))
        let names = Dictionary(uniqueKeysWithValues: try Provider.load(from: runtime.root).map { ($0.id, $0.name) })
        let now = Date()
        let ms = now.timeIntervalSince1970 * 1000
        func iso(_ hours: Double) -> JSONValue { .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(hours * 3600))) }
        func limit(_ label: String, _ percent: Double, _ hours: Double) -> JSONValue {
            .object(["label": .string(label), "percent": .number(percent), "resetsAt": iso(hours)])
        }
        func days(_ base: Double) -> JSONValue {
            .array((0..<7).reversed().map { offset in
                let date = Calendar.current.date(byAdding: .day, value: -offset, to: now)!
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
                let count = (base * (0.55 + Double((offset * 37) % 9) / 10)).rounded()
                return .object(["date": .string(f.string(from: date)), "messageCount": .number(count), "totalTokens": .number(count * 5_200)])
            })
        }
        func record(_ id: String, plan: String, limits: [JSONValue] = [], balance: JSONValue? = nil, prompts: Double,
                    models: [String: Double] = [:], extra: [String: JSONValue] = [:]) -> JSONValue {
            var o: [String: JSONValue] = [
                "schemaVersion": .number(1), "id": .string(id), "name": .string(names[id] ?? id), "ready": .bool(true),
                "tierLabel": .string(plan), "limits": .array(limits), "limitsFetchedAt": .number(ms), "limitsStale": .bool(false),
                "usageStatusText": .string(""), "authHelpText": .string(""),
                "todayPrompts": .number(prompts), "todaySessions": .number((prompts / 9).rounded()), "todayTotalTokens": .number(prompts * 5_400),
                "totalPrompts": .number(prompts * 40), "activeDays": .number(38), "recentDays": days(prompts),
                "modelUsage": .object(models.mapValues { .object(["inputTokens": .number($0 * 0.7), "outputTokens": .number($0 * 0.3), "totalTokens": .number($0)]) }),
            ]
            if let balance { o["balance"] = balance }
            o.merge(extra) { _, new in new }
            return .object(o)
        }
        func account(_ id: String, _ plan: String, _ limits: [JSONValue], active: Bool) -> JSONValue {
            .object(["id": .string(id), "plan": .string(plan), "limits": .array(limits), "stale": .bool(false),
                     "usageStatusText": .string(""), "fetchedAt": .number(ms), "active": .bool(active)])
        }
        let claudeLimits = [limit("Session (5-hour)", 0.42, 2.5), limit("Weekly (7-day)", 0.71, 61)]
        let codexLimits = [limit("5h window", 0.88, 1.2), limit("Weekly (7-day)", 0.64, 90)]
        let records: [JSONValue] = [
            record("claude", plan: "Max 5x", limits: claudeLimits, prompts: 64, models: ["model-large": 2_400_000, "model-fast": 610_000],
                   extra: ["accounts": .array([account("primary", "Max 5x", claudeLimits, active: true),
                                               account("demo-work", "Team", [limit("Session (5-hour)", 0.12, 4), limit("Weekly (7-day)", 0.33, 120)], active: false)])]),
            record("codex", plan: "Plus", limits: codexLimits, prompts: 41, models: ["model-codex": 1_900_000],
                   extra: ["accounts": .array([account("primary", "Plus", codexLimits, active: true),
                                               account("demo-spare", "Plus", [limit("5h window", 0.05, 3), limit("Weekly (7-day)", 0.22, 70)], active: false)])]),
            record("copilot", plan: "Pro", limits: [limit("Monthly allowance (est.)", 0.37, 400)], prompts: 12),
            record("cursor", plan: "Pro", limits: [limit("Included usage", 0.54, 300)], prompts: 18),
            record("deepseek", plan: "Prepaid", balance: .object(["remaining": .number(18.42), "funded": .number(25), "spent": .number(6.58), "currency": .string("USD"), "estimated": .bool(true)]), prompts: 9),
            record("openrouter", plan: "Credits", balance: .object(["remaining": .number(42.10), "funded": .number(50), "spent": .number(7.90), "currency": .string("USD"), "estimated": .bool(false)]), prompts: 7),
            record("hermes", plan: "", prompts: 5),
            record("ollama", plan: "Local", prompts: 3, extra: ["limitsStale": .bool(true), "usageStatusText": .string("Showing previous data")]),
        ]
        for value in records {
            try store.write(value, to: store.paths.usage.appendingPathComponent(value["id"].string + ".json"), backup: false)
        }
        for (provider, label, id) in [("claude", "Work (demo)", "demo-work"), ("codex", "Spare (demo)", "demo-spare")] {
            var registry = AccountRegistry()
            registry.accounts = [Account(id: "primary", label: "Personal (demo)", home: "/demo/primary", primary: true, pendingLogin: false),
                                 Account(id: id, label: label, home: "/demo/\(id)", pendingLogin: false)]
            registry.switch = provider == "codex" ? "auto" : "manual"
            try store.write(registry, to: store.paths.accounts.appendingPathComponent(provider + ".json"))
        }
        return store
    }
}
