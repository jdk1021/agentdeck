import Foundation
import Darwin

public struct DeckPaths: Sendable {
    public let root: URL
    public let home: URL
    public var accounts: URL { root.appendingPathComponent("accounts", isDirectory: true) }
    public var usage: URL { root.appendingPathComponent("usage", isDirectory: true) }
    public var cache: URL { root.appendingPathComponent("cache", isDirectory: true) }
    public static var userHome: URL {
        ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.homeDirectoryForCurrentUser
    }
    public init(root: URL? = nil, home: URL = DeckPaths.userHome) {
        self.home = home
        self.root = root ?? ProcessInfo.processInfo.environment["AGENTDECK_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent("Library/Application Support/AgentDeck", isDirectory: true)
    }
    public func prepare() throws {
        for directory in [root, accounts, usage, cache] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
}

public final class DiskStore: @unchecked Sendable {
    public let paths: DeckPaths
    public init(paths: DeckPaths = DeckPaths()) throws { self.paths = paths; try paths.prepare() }
    public func read<T: Decodable>(_ type: T.Type, at url: URL, fallback: @autoclosure () -> T) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback() }
        do { return try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
        catch { throw DeckError.message("Cannot read \(url.lastPathComponent). Original preserved; restore its .previous backup. \(error.localizedDescription)") }
    }
    public func locked<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        let fd = open(url.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw DeckError.message("Cannot open state lock") }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw DeckError.message("Cannot lock state") }
        return try body()
    }
    public func write<T: Encodable>(_ value: T, to url: URL, backup: Bool = true) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        if backup, let old = try? Data(contentsOf: url) {
            try old.write(to: url.appendingPathExtension("previous"), options: [.atomic])
            chmod(url.path + ".previous", 0o600)
        }
        // Foundation's atomic writer renames a complete same-volume file. fsync before returning.
        try data.write(to: url, options: [.atomic])
        chmod(url.path, 0o600)
        let fd = open(url.path, O_RDONLY); if fd >= 0 { fsync(fd); close(fd) }
        let dir = open(url.deletingLastPathComponent().path, O_RDONLY); if dir >= 0 { fsync(dir); close(dir) }
    }
    public var settingsURL: URL { paths.root.appendingPathComponent("settings.json") }
    public func settings() throws -> DeckSettings { try read(DeckSettings.self, at: settingsURL, fallback: DeckSettings()) }
    public func saveSettings(_ settings: DeckSettings) throws {
        var s = settings; s.refreshInterval = min(3600, max(30, s.refreshInterval))
        try locked(settingsURL) { try write(s, to: settingsURL) }
    }
    public func records() throws -> [UsageRecord] {
        try FileManager.default.contentsOfDirectory(at: paths.usage, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try UsageRecord(data: Data(contentsOf: $0)) }
    }
    public func restore(_ url: URL) throws {
        guard url.standardizedFileURL.path.hasPrefix(paths.root.standardizedFileURL.path + "/") else { throw DeckError.message("Not app-owned state") }
        try locked(url) {
            let data = try Data(contentsOf: url.appendingPathExtension("previous"))
            _ = try JSONDecoder().decode(JSONValue.self, from: data)
            try data.write(to: url, options: .atomic); chmod(url.path, 0o600)
        }
    }
}
