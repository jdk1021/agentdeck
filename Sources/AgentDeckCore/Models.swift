import Foundation

public enum DeckError: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}

/// Preserve additional upstream fields instead of silently discarding new balance formats.
public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .object(v): try c.encode(v)
        case let .array(v): try c.encode(v)
        case let .string(v): try c.encode(v)
        case let .number(v): try c.encode(v)
        case let .bool(v): try c.encode(v)
        }
    }
    public subscript(_ key: String) -> JSONValue { if case let .object(o) = self { return o[key] ?? .null }; return .null }
    public var string: String { if case let .string(s) = self { return s }; return "" }
    public var double: Double? { if case let .number(n) = self, n.isFinite { return n }; return nil }
    public var bool: Bool { if case let .bool(b) = self { return b }; return false }
    public var array: [JSONValue] { if case let .array(a) = self { return a }; return [] }
    public var object: [String: JSONValue] { if case let .object(o) = self { return o }; return [:] }
}

public struct UsageLimit: Equatable, Sendable, Identifiable {
    public let label: String
    public let percent: Double
    public let resetsAt: Date?
    public var id: String { label }
    public init?(_ json: JSONValue) {
        guard let value = json["percent"].double, (0...1).contains(value) else { return nil }
        label = json["label"].string; percent = value
        resetsAt = DeckDate.parse(json["resetsAt"].string)
    }
    public func level(at now: Date) -> Double { resetsAt.map { $0 <= now } == true ? 0 : percent }
}

public enum DeckDate {
    public static func parse(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

public struct UsageRecord: Identifiable, Sendable {
    public var raw: JSONValue
    public var id: String { raw["id"].string }
    public var name: String { raw["name"].string }
    public var ready: Bool { raw["ready"].bool }
    public var plan: String { raw["tierLabel"].string }
    public var limits: [UsageLimit] { raw["limits"].array.compactMap(UsageLimit.init) }
    public var accounts: [JSONValue] { raw["accounts"].array }
    public var fetchedAt: Date? { raw["limitsFetchedAt"].double.map { Date(timeIntervalSince1970: $0 / 1000) } }
    public var updatedAt: Date? { DeckDate.parse(raw["updatedAt"].string) }
    public var isStale: Bool {
        raw["limitsStale"].bool || raw["collectorFailed"].bool ||
        ((!limits.isEmpty || !raw["balance"].object.isEmpty) && fetchedAt.map { Date().timeIntervalSince($0) > 1800 } == true)
    }
    public var status: String { raw["usageStatusText"].string }
    public var authHelp: String { raw["authHelpText"].string }
    public var peak: Double? { limits.map { $0.level(at: Date()) }.max() }
    public init(raw: JSONValue) throws {
        guard !raw["id"].string.isEmpty, !raw["name"].string.isEmpty,
              raw["schemaVersion"].double == 1 else { throw DeckError.message("Invalid collector record") }
        self.raw = raw
    }
    public init(data: Data) throws { try self.init(raw: JSONDecoder().decode(JSONValue.self, from: data)) }
}

public struct Account: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var home: String
    public var primary: Bool
    public var pendingLogin: Bool
    public init(id: String, label: String, home: String, primary: Bool = false, pendingLogin: Bool = true) {
        self.id = id; self.label = label; self.home = home; self.primary = primary; self.pendingLogin = pendingLogin
    }
}

public struct AccountRegistry: Codable, Sendable {
    public var accounts: [Account] = []
    public var active = "primary"
    public var `switch` = "manual"
    public var threshold = 95
    public var alert = ""
    public var lastSwitchAt: Double = 0
    public init() {}
}

public struct DeckSettings: Codable, Sendable {
    public var refreshInterval = 900
    public var notifications = true
    public var syncDirectory = ""
    public var deviceID = UUID().uuidString
    public var disabledProviders: [String] = []
    public init() {}
}

public struct Provider: Identifiable, Codable, Sendable {
    public let id: String
    public let name: String
    public var supportsAccounts: Bool { ["claude", "codex", "grok"].contains(id) }
    public var homeVariable: String? { ["claude": "CLAUDE_CONFIG_DIR", "codex": "CODEX_HOME", "grok": "GROK_HOME"][id] }
    public var executable: String? {
        ["claude":"claude", "codex":"codex", "grok":"grok", "kimi":"kimi", "cursor":"agent",
         "grokbot":"grokbot", "copilot":"copilot", "muse":"muse", "agy":"agy", "kimchi":"kimchi",
         "hermes":"hermes", "devin":"devin", "vibe":"vibe", "qwen":"qwen", "opencode":"opencode",
         "ollama":"ollama", "minimax":"mmx"][id]
    }
    public var loginArguments: [String] {
        switch id {
        case "claude": return ["auth", "login"]
        case "codex", "grok", "kimi", "agent", "devin", "cursor": return ["login"]
        case "opencode": return ["auth", "login"]
        default: return [] // Interactive CLI handles its own provider-specific login.
        }
    }
    public static func load(from runtime: URL) throws -> [Provider] {
        struct Inventory: Decodable { let collectors: [Provider] }
        return try JSONDecoder().decode(Inventory.self, from: Data(contentsOf: runtime.appendingPathComponent("inventory.json"))).collectors
    }
}
