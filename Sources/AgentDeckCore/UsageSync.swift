import Foundation

/// Usage-only projection. No account IDs, auth, email, host name, transcript, or endpoint leaves the machine.
public struct UsageSync {
    public let store: DiskStore
    public init(store: DiskStore) { self.store = store }
    private static let numeric = ["todayPrompts", "todaySessions", "todayTotalTokens", "totalPrompts", "totalSessions", "activeDays"]
    private static let bucketKeys: Set<String> = ["inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens", "totalTokens", "prompts", "sessions", "messageCount"]
    public static func projection(_ record: UsageRecord) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(record.id)]
        for key in numeric { if let n = record.raw[key].double, n >= 0, n <= 1e15 { o[key] = .number(n) } }
        o["activeDates"] = .array(record.raw["activeDates"].array.filter { validDay($0.string) })
        o["recentDays"] = .array(record.raw["recentDays"].array.compactMap { row in
            guard validDay(row["date"].string) else { return nil }
            var b = bucket(row); b["date"] = .string(row["date"].string)
            return .object(b)
        })
        for key in ["modelUsage", "todayTokensByModel"] {
            o[key] = .object(record.raw[key].object.mapValues { .object(bucket($0)) })
        }
        return .object(o)
    }
    private static func bucket(_ value: JSONValue) -> [String: JSONValue] {
        value.object.filter { bucketKeys.contains($0.key) && ($0.value.double.map { $0 >= 0 && $0 <= 1e15 } ?? false) }
    }
    private static func validDay(_ value: String) -> Bool { value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil }
    public func export(records: [UsageRecord], settings: DeckSettings) throws {
        guard UUID(uuidString: settings.deviceID) != nil else { throw DeckError.message("Invalid sync device identifier") }
        let folder = URL(fileURLWithPath: settings.syncDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let value: JSONValue = .object(["schemaVersion": .number(1), "deviceID": .string(settings.deviceID),
                                        "updatedAt": .string(ISO8601DateFormatter().string(from: Date())),
                                        "providers": .array(records.map(Self.projection))])
        try store.write(value, to: folder.appendingPathComponent("agentdeck-\(settings.deviceID).json"), backup: false)
    }
    public func aggregate(settings: DeckSettings, records: [UsageRecord]) throws -> [JSONValue] {
        guard !settings.syncDirectory.isEmpty else { return records.map(Self.projection) }
        let folder = URL(fileURLWithPath: settings.syncDirectory)
        var latest: [String: (Date, [JSONValue])] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]) where file.lastPathComponent.hasPrefix("agentdeck-") && file.pathExtension == "json" {
            guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max) < 5_000_000,
                  let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                  value["schemaVersion"].double == 1,
                  UUID(uuidString: value["deviceID"].string) != nil,
                  let date = DeckDate.parse(value["updatedAt"].string), date < Date().addingTimeInterval(300) else { continue }
            let device = value["deviceID"].string
            if device == settings.deviceID { continue }
            if latest[device] == nil || latest[device]!.0 < date { latest[device] = (date, value["providers"].array) }
        }
        var grouped: [String: [JSONValue]] = [:]
        let today = DateFormatter(); today.dateFormat = "yyyy-MM-dd"
        let day = today.string(from: Date())
        let all = [(Date(), records.map(Self.projection))] + Array(latest.values)
        for (date, values) in all {
            for value in values {
                guard let known = records.first(where: { $0.id == value["id"].string }) else { continue }
                // Validate remote fields using the same allowlist as exports.
                var validated = Self.projection(try UsageRecord(raw: .object(value.object.merging([
                    "schemaVersion": .number(1), "name": .string(known.name)
                ], uniquingKeysWith: { _, new in new })))).object
                if today.string(from: date) != day {
                    for key in ["todayPrompts", "todaySessions", "todayTotalTokens"] { validated[key] = .number(0) }
                    validated["todayTokensByModel"] = .object([:])
                }
                grouped[value["id"].string, default: []].append(.object(validated))
            }
        }
        return grouped.keys.sorted().map { id in
            let rows = grouped[id]!
            var o: [String: JSONValue] = ["id": .string(id)]
            // Lifetime figures can include shared history; upstream takes the widest rather than summing it.
            for key in Self.numeric {
                let values = rows.compactMap { $0[key].double }
                o[key] = .number(key.hasPrefix("today") ? values.reduce(0, +) : (values.max() ?? 0))
            }
            var dates = Set<String>(); var days: [String: [String: Double]] = [:]
            for row in rows {
                dates.formUnion(row["activeDates"].array.map(\.string))
                for d in row["recentDays"].array {
                    for (key, v) in Self.bucket(d) { days[d["date"].string, default: [:]][key, default: 0] += v.double ?? 0 }
                }
            }
            o["activeDates"] = .array(dates.sorted().map(JSONValue.string))
            o["recentDays"] = .array(days.keys.sorted().map { date in
                .object(days[date]!.mapValues(JSONValue.number).merging(["date": .string(date)], uniquingKeysWith: { _, new in new }))
            })
            for key in ["modelUsage", "todayTokensByModel"] {
                var models: [String: [String: Double]] = [:]
                for row in rows {
                    for (model, b) in row[key].object {
                        for (field, v) in Self.bucket(b) {
                            let n = v.double ?? 0
                            models[model, default: [:]][field] = key == "modelUsage" ? max(models[model]?[field] ?? 0, n) : (models[model]?[field] ?? 0) + n
                        }
                    }
                }
                o[key] = .object(models.mapValues { .object($0.mapValues(JSONValue.number)) })
            }
            return .object(o)
        }
    }
}
