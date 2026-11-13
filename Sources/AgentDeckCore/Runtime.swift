import Foundation
import Darwin

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
}

/// This process's own executable, symlinks resolved. Asked from the kernel because argv[0] is just
/// "agentdeck" when the CLI is started by name through a PATH link (Homebrew, ~/.local/bin).
public enum CurrentExecutable {
    public static var url: URL {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 {
            return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
        }
        return (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    }
}

public enum ChildProcess {
    /// Runs a helper in its own process group. On timeout, or when descendants outlive it while holding
    /// its output open, only that group is signalled — never the user's shells or agent sessions.
    public static func run(_ executable: URL, _ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment,
                           timeout: TimeInterval = 90) throws -> ProcessResult {
        var outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { throw DeckError.message("Cannot create pipe") }
        guard pipe(&errPipe) == 0 else { close(outPipe[0]); close(outPipe[1]); throw DeckError.message("Cannot create pipe") }
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions); defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        for fd in [outPipe[0], outPipe[1], errPipe[0], errPipe[1]] { posix_spawn_file_actions_addclose(&actions, fd) }
        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes); defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        close(outPipe[1]); close(errPipe[1])
        guard spawned == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw DeckError.message("Cannot launch \(executable.lastPathComponent): \(String(cString: strerror(spawned)))")
        }
        let group = DispatchGroup()
        let output = DataBox(), errors = DataBox()
        let outHandle = FileHandle(fileDescriptor: outPipe[0], closeOnDealloc: true)
        let errHandle = FileHandle(fileDescriptor: errPipe[0], closeOnDealloc: true)
        group.enter(); DispatchQueue.global().async { output.data = outHandle.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { errors.data = errHandle.readDataToEndOfFile(); group.leave() }
        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0, exited = false
        while Date() < deadline {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid || (r < 0 && errno != EINTR) { exited = true; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if !exited {
            terminateGroup(pid)
            waitpid(pid, &status, 0)
            _ = group.wait(timeout: .now() + 2)
            throw DeckError.message("Command timed out: \(executable.lastPathComponent)")
        }
        // A leftover descendant that keeps the pipes open must not block the refresh.
        if group.wait(timeout: .now() + 2) == .timedOut {
            terminateGroup(pid)
            _ = group.wait(timeout: .now() + 2)
        } else if killpg(pid, 0) == 0 {
            terminateGroup(pid)
        }
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return ProcessResult(status: code, stdout: output.data, stderr: errors.data)
    }
    private static func terminateGroup(_ pgid: pid_t) {
        guard pgid > 1 else { return }
        killpg(pgid, SIGTERM)
        for _ in 0..<10 where killpg(pgid, 0) == 0 { Thread.sleep(forTimeInterval: 0.02) }
        if killpg(pgid, 0) == 0 { killpg(pgid, SIGKILL) }
    }
    private final class DataBox: @unchecked Sendable { var data = Data() }
}

public struct CLIResolver: Sendable {
    public var environment: [String: String]
    public var home: URL
    public init(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = DeckPaths.userHome) {
        self.environment = environment; self.home = home
    }
    public var searchPaths: [String] {
        let paths = [home.appendingPathComponent(".local/share/mise/shims").path, "/opt/homebrew/bin", "/usr/local/bin",
                     home.appendingPathComponent(".local/bin").path, home.appendingPathComponent(".npm-global/bin").path,
                     home.appendingPathComponent(".bun/bin").path, home.appendingPathComponent(".opencode/bin").path,
                     "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        return ((environment["PATH"] ?? "").components(separatedBy: ":") + paths).filter { !$0.isEmpty }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
    public var childEnvironment: [String: String] {
        var env = environment; env["PATH"] = searchPaths.joined(separator: ":"); env["MISE_OFFLINE"] = "1"; return env
    }
    public func find(_ name: String, useMise: Bool = true) throws -> URL {
        guard name.range(of: #"^[a-zA-Z0-9._+-]+$"#, options: .regularExpression) != nil else { throw DeckError.message("Invalid executable name") }
        let fm = FileManager.default
        if useMise, name != "mise", let mise = try? find("mise", useMise: false),
           let result = try? ChildProcess.run(mise, ["which", name], environment: childEnvironment, timeout: 12), result.status == 0,
           let path = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           path.hasPrefix("/"), fm.isExecutableFile(atPath: path), !isWrapper(URL(fileURLWithPath: path)) {
            return URL(fileURLWithPath: path)
        }
        for path in searchPaths {
            let url = URL(fileURLWithPath: path).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: url.path), !isWrapper(url), !path.hasSuffix("/mise/shims") { return url }
        }
        throw DeckError.message("\(name) is not installed. Install it with your existing mise or provider installer.")
    }
    public func isWrapper(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        if resolved.lastPathComponent == "agentdeck" { return true }
        guard let handle = try? FileHandle(forReadingFrom: resolved) else { return false }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 512)) ?? Data()
        return String(data: prefix, encoding: .utf8)?.contains("AGENTDECK_WRAPPER") == true
    }
}

public struct CollectorRuntime: Sendable {
    public let root: URL
    public let python: URL
    public init(root: URL? = nil, resolver: CLIResolver = CLIResolver()) throws {
        let envRoot = ProcessInfo.processInfo.environment["AGENTDECK_RUNTIME"].map { URL(fileURLWithPath: $0) }
        let exe = CurrentExecutable.url
        let candidates = [root, envRoot, Bundle.main.resourceURL?.appendingPathComponent("Runtime"),
                          exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Runtime"),
                          URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Runtime")].compactMap { $0 }
        guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("inventory.json").path) }) else {
            throw DeckError.message("Collector runtime missing. Run scripts/prepare-runtime.py or install the .app package.")
        }
        self.root = found
        let bundled = found.appendingPathComponent("python/bin/python3")
        self.python = FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : try resolver.find("python3")
        let result = try ChildProcess.run(python, ["-B", "-c", "import sys; assert sys.version_info >= (3, 11)"], timeout: 10)
        guard result.status == 0 else { throw DeckError.message("Collectors require Python 3.11 or later") }
    }
    public func environment(store: DiskStore, resolver: CLIResolver) -> [String: String] {
        var env = ProviderSecrets.environment(resolver.childEnvironment)
        env["AGENTDECK_RUNTIME"] = root.path
        env["AGENTDECK_MACOS"] = "1"
        if ProcessInfo.processInfo.environment["AGENTDECK_FIXTURE_MODE"] == "1" { env["AGENTDECK_MACOS"] = "0" }
        env["AGENTDECK_ACCOUNTS_DIR"] = store.paths.accounts.path
        env["AGENTDECK_CACHE_DIR"] = store.paths.cache.path
        env["AGENTDECK_PROVIDER_CONFIG_DIR"] = store.paths.root.appendingPathComponent("providers").path
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        // Do not import arbitrary login-shell Python modules into the collector process.
        env.removeValue(forKey: "PYTHONPATH"); env.removeValue(forKey: "PYTHONHOME")
        if let codex = try? resolver.find("codex") { env["AGENTDECK_CODEX_BINARY"] = codex.path }
        return env
    }
}
