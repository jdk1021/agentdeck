import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications
import AgentDeckCore

@main
struct AgentDeckApp: App {
    @NSApplicationDelegateAdaptor(DeckAppDelegate.self) private var appDelegate
    @StateObject private var model = DeckModel()
    var body: some Scene {
        MenuBarExtra {
            MenuPanel().environmentObject(model)
        } label: {
            MenuBarLabel().environmentObject(model)
        }.menuBarExtraStyle(.window)
        Window("AgentDeck", id: "dashboard") {
            Dashboard().environmentObject(model)
        }.defaultSize(width: 1080, height: 760)
        // Demo/screenshot aid: the menu bar panel's content in an ordinary window.
        Window("AgentDeck Panel", id: "panel-preview") {
            MenuPanel().environmentObject(model).background(Deck.background)
        }.windowResizability(.contentSize)
        Settings {
            SettingsPanel().environmentObject(model)
        }
        .commands { CommandGroup(after: .newItem) {
            Button("Refresh Usage") { model.refresh(force: true) }.keyboardShortcut("r")
        } }
    }
}

final class DeckAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !DemoData.enabled, !CommandLine.arguments.contains("--open-dashboard") else { return }
        for window in NSApp.windows where window.title == "AgentDeck" || window.title == "AgentDeck Panel" {
            window.close()
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { false }
    func applicationShouldRestoreSecureApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool { false }
}

struct MenuBarLabel: View {
    @EnvironmentObject var model: DeckModel
    @Environment(\.openWindow) var openWindow
    @Environment(\.openSettings) var openSettings
    @State private var handledLaunch = false
    var body: some View {
        Image(nsImage: model.menuStatus.image)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AgentDeck, \(model.menuStatus.description)")
        .help(model.menuStatus.description)
        .onAppear {
            guard !handledLaunch else { return }
            handledLaunch = true
            // Demo mode is for screenshots and UI checks: show the windows straight away.
            if let style = DemoData.option("--demo-appearance") { NSApp.appearance = NSAppearance(named: style == "dark" ? .darkAqua : .aqua) }
            if model.demo && CommandLine.arguments.contains("--panel-preview") {
                openWindow(id: "panel-preview")
            } else if model.demo && CommandLine.arguments.contains("--demo-settings") {
                openSettings()
            } else if model.demo || CommandLine.arguments.contains("--open-dashboard") {
                openWindow(id: "dashboard")
            }
            if model.demo || CommandLine.arguments.contains("--open-dashboard") { NSApp.activate(ignoringOtherApps: true) }
        }
    }
}

@MainActor
final class DeckModel: ObservableObject {
    @Published var providers: [Provider] = []
    @Published var records: [UsageRecord] = []
    @Published var registries: [String: AccountRegistry] = [:]
    @Published var settings = DeckSettings()
    @Published var refreshing = false
    @Published var error: String?
    @Published var lastRefresh: Date?
    @Published var eventText = ""
    @Published var aggregated: [JSONValue] = []
    @Published var selection: String? = DemoData.option("--demo-select") ?? "claude"
    private(set) var store: DiskStore?
    private(set) var runtime: CollectorRuntime?
    private(set) var service: CollectorService?
    private(set) var accounts: AccountManager?
    private var timer: Task<Void, Never>?
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var keyObserver: NSObjectProtocol?
    private var lastFull = Date.distantPast
    let demo = DemoData.enabled
    init() {
        do {
            let runtime = try CollectorRuntime()
            let store = demo ? try DemoData.makeStore(runtime: runtime) : try DiskStore()
            self.store = store; self.runtime = runtime
            // Demo mode never runs collectors: it shows only synthetic records.
            service = demo ? nil : try CollectorService(store: store, runtime: runtime)
            accounts = AccountManager(store: store, runtime: runtime)
            providers = try Provider.load(from: runtime.root)
            settings = try store.settings(); records = try store.records()
            if demo { refreshing = CommandLine.arguments.contains("--demo-refreshing") }
            // Opening the menu bar panel or the dashboard checks right away (see refreshOnOpen).
            keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshOnOpen() }
            }
            watch(store.paths.accounts) { $0.reloadRegistries() }
            watch(store.paths.usage) { $0.reloadRecords() }
        } catch {
            store = nil; runtime = nil; service = nil; accounts = nil; self.error = error.localizedDescription
        }
        Task { self.reloadRegistries(); self.refresh() }
    }
    /// CLI logins, `agentdeck account …` and other processes change these directories; reflect them
    /// without waiting for the next refresh. Writes are atomic renames, which signal the directory.
    private func watch(_ directory: URL, _ action: @escaping @MainActor (DeckModel) -> Void) {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        var pending = false
        source.setEventHandler { [weak self] in
            guard !pending else { return }
            pending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                pending = false
                MainActor.assumeIsolated { if let self { action(self) } }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watchers.append(source)
    }
    /// A fresh check whenever the panel or dashboard is opened, unless one finished moments ago.
    /// Collectors keep their own short reuse windows, so this never floods a provider's API.
    func refreshOnOpen() {
        guard !refreshing else { return }
        if let last = lastRefresh, Date().timeIntervalSince(last) < 15 { return }
        refresh()
    }
    func reloadRecords() {
        guard !refreshing, let store, let fresh = try? store.records() else { return }
        records = fresh
    }
    var menuStatus: DeckMenuStatus {
        let ready = records.filter(\.ready)
        let peak = ready.filter { !$0.isStale }.compactMap(\.peak).max() ?? 0
        if peak >= 0.95 { return .critical }
        if peak >= 0.8 { return .warning }
        if ready.contains(where: \.isStale) { return .stale }
        return .normal
    }
    var cli: URL {
        Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("agentdeck")
    }
    func reloadRegistries() {
        guard let accounts else { return }
        do { registries = Dictionary(uniqueKeysWithValues: try providers.filter(\.supportsAccounts).map { ($0.id, try accounts.registry($0)) }) }
        catch { self.error = error.localizedDescription }
    }
    func record(_ id: String) -> UsageRecord? { records.first { $0.id == id } }
    func refresh(force: Bool = false, limits: Bool = false, only: Set<String>? = nil) {
        guard !refreshing, let service else { return }
        timer?.cancel(); refreshing = true
        Task {
            do {
                let result = try await service.refresh(force: force, limitsOnly: limits, only: only)
                if !limits { lastFull = Date() }
                records = result.records; lastRefresh = Date(); reloadRegistries()
                for event in result.events { eventText = event.title + ": " + event.body; await notify(event) }
                if let store { aggregated = (try? UsageSync(store: store).aggregate(settings: settings, records: records)) ?? [] }
            } catch { self.error = error.localizedDescription }
            refreshing = false; schedule()
        }
    }
    func schedule() {
        guard service != nil else { return }
        timer?.cancel()
        let next = RefreshSchedule.step(settings: settings, records: records, registries: registries, lastFull: lastFull)
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(next.seconds)); self?.refresh(limits: next.limitsOnly, only: next.only) }
            catch { }
        }
    }
    func perform(_ action: () throws -> Void) {
        do { try action(); reloadRegistries(); refresh() } catch { self.error = error.localizedDescription }
    }
    func saveSettings() {
        do { try store?.saveSettings(settings); schedule() } catch { self.error = error.localizedDescription }
    }
    func launch(_ provider: Provider, account: String? = nil, login: Bool = false) {
        guard let store else { return }
        guard !demo else { error = "Demo mode shows synthetic data only; Terminal sessions are disabled."; return }
        var args: [String]
        if login {
            args = provider.supportsAccounts ? ["account", "login", provider.id, account ?? "primary"] : ["login", provider.id]
        } else {
            args = ["run", provider.id]
            if let account { args += ["--account", account] }; args.append("--")
        }
        do {
            let file = try SessionLauncher.commandFile(cli: cli, arguments: args, directory: store.paths.home, store: store, closeOnSuccess: login)
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([file], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: config) { _, error in
                if let error { Task { @MainActor in self.error = error.localizedDescription } }
            }
        } catch { self.error = error.localizedDescription }
    }
    func add(_ provider: Provider, label: String) {
        guard let accounts else { return }
        perform { let account = try accounts.add(provider, label: label); launch(provider, account: account.id, login: true) }
    }
    func notify(_ event: DeckEvent) async {
        guard settings.notifications else { return }
        let center = UNUserNotificationCenter.current()
        do {
            let permitted = try await center.requestAuthorization(options: [.alert, .sound])
            guard permitted else { return }
            let content = UNMutableNotificationContent(); content.title = event.title; content.body = event.body
            try await center.add(UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil))
        } catch { eventText += " (Notification unavailable)" }
    }
}

