import SwiftUI
import AppKit
import ServiceManagement
import AgentDeckCore

// MARK: - Shared helpers

extension UsageRecord {
    var balance: JSONValue? { raw["balance"].object.isEmpty ? nil : raw["balance"] }
    var topLimit: UsageLimit? { limits.max { $0.level(at: Date()) < $1.level(at: Date()) } }
}

private func compact(_ value: Double?) -> String {
    guard let value else { return "—" }
    return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
}

private let dayParser: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()

// MARK: - Menu bar panel

struct MenuPanel: View {
    @EnvironmentObject var model: DeckModel
    @Environment(\.openWindow) var openWindow
    @Environment(\.openSettings) var openSettings
    @State private var query = ""

    var rows: [Provider] {
        model.providers.filter { p in
            query.isEmpty ? model.record(p.id)?.ready == true
                : p.name.localizedCaseInsensitiveContains(query) || p.id.contains(query.lowercased())
        }.sorted { (model.record($0.id)?.peak ?? -1) > (model.record($1.id)?.peak ?? -1) }
    }
    var highest: (Provider, UsageLimit)? {
        model.providers.compactMap { p -> (Provider, UsageLimit)? in
            guard let r = model.record(p.id), r.ready, let l = r.topLimit else { return nil }
            return (p, l)
        }.max { $0.1.level(at: Date()) < $1.1.level(at: Date()) }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: DeckGlyph.image).renderingMode(.template).foregroundStyle(Deck.accent)
                Text("AgentDeck").font(.system(size: 16, weight: .bold)).foregroundStyle(Deck.text)
                if model.demo { Pill(text: "Demo", foreground: Deck.accent, background: Deck.accentSoft) }
                Spacer()
                if model.refreshing { ProgressView().controlSize(.small) }
                IconButton(symbol: "arrow.clockwise", help: "Refresh all providers") { model.refresh(force: true) }
                    .disabled(model.refreshing)
            }
            if let (provider, limit) = highest { summary(provider, limit) }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Deck.tertiary)
                TextField("Search 23 providers", text: $query).textFieldStyle(.plain).font(.system(size: 13))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Deck.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(rows) { provider in PanelRow(provider: provider) }
                    if rows.isEmpty {
                        DeckCard {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(query.isEmpty ? "No agent in use yet" : "No match").font(.system(size: 14, weight: .bold)).foregroundStyle(Deck.text)
                                Text("Open the dashboard to sign in to an agent or save a provider key.").font(.system(size: 12)).foregroundStyle(Deck.secondary)
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            // A menu bar window sizes to its content, so give the list a real height.
            .frame(height: min(430, max(96, CGFloat(rows.count) * 118)))
            if let error = model.error { Banner(tone: .danger, symbol: "exclamationmark.triangle.fill", text: error).lineLimit(4) }
            HStack(spacing: 8) {
                Button("Open Dashboard") { openWindow(id: "dashboard"); NSApp.activate(ignoringOtherApps: true) }
                    .buttonStyle(DeckButtonStyle(kind: .primary)).keyboardShortcut("d")
                Button { openSettings(); NSApp.activate(ignoringOtherApps: true) } label: { Image(systemName: "gearshape.fill") }
                    .buttonStyle(DeckButtonStyle(kind: .secondary)).help("Settings").accessibilityLabel("Settings")
                Spacer()
                if let date = model.lastRefresh {
                    Text(date.formatted(date: .omitted, time: .shortened)).font(.system(size: 11)).foregroundStyle(Deck.tertiary)
                }
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(DeckButtonStyle(kind: .plain, compact: true)).keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 380)
        .background(Deck.background)
    }

    func summary(_ provider: Provider, _ limit: UsageLimit) -> some View {
        let level = limit.level(at: Date())
        return DeckCard(padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Highest usage right now").font(.system(size: 12, weight: .medium)).foregroundStyle(Deck.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Deck.percent(level)).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(Deck.tint(for: level)).monospacedDigit()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(provider.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Deck.text)
                        Text(limit.label).font(.system(size: 12)).foregroundStyle(Deck.secondary)
                    }
                    Spacer()
                    if let reset = limit.resetsAt { Text(Deck.resetText(reset)).font(.system(size: 11, weight: .medium)).foregroundStyle(Deck.tertiary) }
                }
                UsageBar(value: level, tint: Deck.tint(for: level))
            }
        }
    }
}

struct PanelRow: View {
    @EnvironmentObject var model: DeckModel
    @Environment(\.openWindow) var openWindow
    let provider: Provider
    var body: some View {
        let record = model.record(provider.id)
        let registry = model.registries[provider.id]
        DeckCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ProviderIcon(id: provider.id, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.name).font(.system(size: 14, weight: .bold)).foregroundStyle(Deck.text)
                        Text(subtitle(record, registry)).font(.system(size: 12)).foregroundStyle(Deck.secondary).lineLimit(1)
                    }
                    Spacer()
                    trailing(record)
                }
                if let record {
                    ForEach(record.limits.prefix(2)) { limit in
                        let level = limit.level(at: Date())
                        VStack(spacing: 5) {
                            HStack {
                                Text(limit.label).font(.system(size: 11, weight: .medium)).foregroundStyle(Deck.secondary)
                                Spacer()
                                Text(Deck.percent(level)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Deck.text).monospacedDigit()
                            }
                            UsageBar(value: level, tint: Deck.tint(for: level, stale: record.isStale), height: 6)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if record.isStale { Text("Previous data · refresh pending").font(.system(size: 11, weight: .medium)).foregroundStyle(Deck.warning) }
                }
                if let registry, registry.accounts.count > 1 {
                    Menu {
                        ForEach(registry.accounts) { account in
                            Button((account.id == registry.active ? "✓ " : "") + account.label) {
                                model.perform { try model.accounts?.use(provider, id: account.id) }
                            }.disabled(account.pendingLogin)
                        }
                    } label: {
                        Label(registry.accounts.first { $0.id == registry.active }?.label ?? "Account", systemImage: "person.crop.circle")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selection = provider.id; openWindow(id: "dashboard"); NSApp.activate(ignoringOtherApps: true) }
    }
    func subtitle(_ record: UsageRecord?, _ registry: AccountRegistry?) -> String {
        var parts: [String] = []
        if let plan = record?.plan, !plan.isEmpty { parts.append(plan) }
        if let registry, registry.accounts.count > 1, let active = registry.accounts.first(where: { $0.id == registry.active }) { parts.append(active.label) }
        if parts.isEmpty, let prompts = record?.raw["todayPrompts"].double { parts.append("\(compact(prompts)) prompts today") }
        return parts.isEmpty ? provider.id : parts.joined(separator: " · ")
    }
    @ViewBuilder func trailing(_ record: UsageRecord?) -> some View {
        if let record, let peak = record.peak {
            Text(Deck.percent(peak)).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(Deck.tint(for: peak, stale: record.isStale)).monospacedDigit()
        } else if let balance = record?.balance, let remaining = balance["remaining"].double {
            VStack(alignment: .trailing, spacing: 1) {
                Text(Deck.money(remaining, balance["currency"].string)).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(Deck.text)
                if balance["estimated"].bool { Text("estimate").font(.system(size: 10, weight: .semibold)).foregroundStyle(Deck.warning) }
            }
        } else {
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Deck.tertiary)
        }
    }
}

// MARK: - Dashboard

struct Dashboard: View {
    @EnvironmentObject var model: DeckModel
    @State private var query = ""
    @State private var filter = "All"
    @State private var sortByUsage = true
    var visible: [Provider] {
        model.providers.filter { provider in
            let record = model.record(provider.id)
            let matches = query.isEmpty || provider.name.localizedCaseInsensitiveContains(query) || provider.id.contains(query.lowercased())
            let passes: Bool
            switch filter {
            case "In use": passes = record?.ready == true
            case "Accounts": passes = provider.supportsAccounts
            case "Attention": passes = record?.isStale == true || !(record?.status ?? "").isEmpty
            default: passes = true
            }
            return matches && passes
        }.sorted {
            if sortByUsage {
                let a = model.record($0.id), b = model.record($1.id)
                if (a?.ready == true) != (b?.ready == true) { return a?.ready == true }
                if (a?.peak ?? -1) != (b?.peak ?? -1) { return (a?.peak ?? -1) > (b?.peak ?? -1) }
            }
            return $0.name < $1.name
        }
    }
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("Filter", selection: $filter) {
                    ForEach(["All", "In use", "Accounts", "Attention"], id: \.self) { Text($0) }
                }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12).padding(.vertical, 8)
                List(visible, selection: $model.selection) { provider in
                    SidebarRow(provider: provider).tag(provider.id)
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 270)
            .searchable(text: $query, placement: .sidebar, prompt: "Search providers")
        } detail: {
            Group {
                if let provider = model.providers.first(where: { $0.id == model.selection }) {
                    ProviderDetail(provider: provider).id(provider.id)
                } else {
                    ContentUnavailableView("Select a provider", systemImage: "square.stack.3d.up")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Deck.background)
        }
        .toolbar {
            ToolbarItemGroup {
                if model.refreshing { ProgressView().controlSize(.small) }
                Toggle(isOn: $sortByUsage) { Label("Sort by usage", systemImage: "arrow.up.arrow.down") }.help("Sort by usage")
                Button { model.refresh(force: true) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(model.refreshing).help("Refresh all providers")
                SettingsLink { Label("Settings", systemImage: "gearshape") }.help("Settings")
            }
        }
        .frame(minWidth: 860, minHeight: 580)
        .alert("AgentDeck", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct SidebarRow: View {
    @EnvironmentObject var model: DeckModel
    let provider: Provider
    var body: some View {
        let record = model.record(provider.id)
        HStack(spacing: 10) {
            ProviderIcon(id: provider.id, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.name).font(.system(size: 13, weight: .semibold))
                Text(caption(record)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if record?.isStale == true {
                Circle().fill(Deck.warning).frame(width: 7, height: 7).accessibilityLabel("Stale data")
            }
            if let peak = record?.peak {
                Text(Deck.percent(peak)).font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Deck.tint(for: peak, stale: record?.isStale == true))
            }
        }
        .padding(.vertical, 3)
    }
    func caption(_ record: UsageRecord?) -> String {
        guard let record, record.ready else { return provider.supportsAccounts ? "Usage · accounts" : "Not in use" }
        if !record.plan.isEmpty { return record.plan }
        if let b = record.balance, let r = b["remaining"].double { return Deck.money(r, b["currency"].string) + (b["estimated"].bool ? " est." : "") }
        return "Local statistics"
    }
}

struct ProviderDetail: View {
    @EnvironmentObject var model: DeckModel
    let provider: Provider
    @State private var newLabel = ""
    @State private var showAdd = false
    @State private var renameID: String?
    @State private var renameText = ""
    var record: UsageRecord? { model.record(provider.id) }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let record {
                    if record.isStale { Banner(tone: .warning, symbol: "clock.badge.exclamationmark", text: "Showing previous data. A successful refresh is required before automatic switching.") }
                    if !record.status.isEmpty { Banner(tone: .info, symbol: "info.circle.fill", text: record.status) }
                    if !record.authHelp.isEmpty { Banner(tone: .info, symbol: "key.fill", text: record.authHelp) }
                    LimitsCard(record: record)
                    if let balance = record.balance { BalanceCard(value: balance) }
                    StatsCard(raw: record.raw, title: "Today")
                    ActivityCard(raw: record.raw)
                    ModelsCard(raw: record.raw)
                    if !model.settings.syncDirectory.isEmpty, let aggregate = model.aggregated.first(where: { $0["id"].string == provider.id }) {
                        StatsCard(raw: aggregate, title: "Across devices · usage only")
                    }
                } else {
                    DeckCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No data yet").font(.system(size: 15, weight: .bold)).foregroundStyle(Deck.text)
                            Text("Refresh to collect this Mac's usage for \(provider.name).").font(.system(size: 13)).foregroundStyle(Deck.secondary)
                        }
                    }
                }
                if provider.supportsAccounts { accountsCard.id("accounts") }
                else {
                    Text("Usage collection only. The upstream collector has no account switching for this provider.")
                        .font(.system(size: 12)).foregroundStyle(Deck.tertiary).padding(.horizontal, 4)
                }
                if !model.eventText.isEmpty { Banner(tone: .info, symbol: "bell.fill", text: model.eventText) }
            }
            .padding(28)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .onAppear {
            if let target = DemoData.option("--demo-scroll") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { withAnimation(nil) { proxy.scrollTo(target, anchor: .top) } }
            }
        }
        }
        .sheet(isPresented: $showAdd) { addSheet }
        .alert("Rename account", isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameID = nil }
            Button("Save") { if let id = renameID { model.perform { try model.accounts?.rename(provider, id: id, label: renameText) } }; renameID = nil }
        }
    }

    var header: some View {
        HStack(spacing: 16) {
            ProviderIcon(id: provider.id, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(provider.name).font(.system(size: 26, weight: .bold)).foregroundStyle(Deck.text)
                HStack(spacing: 6) {
                    if let plan = record?.plan, !plan.isEmpty { Pill(text: plan, foreground: Deck.accent, background: Deck.accentSoft) }
                    if let date = record?.fetchedAt { Text("Measured \(date.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 12)).foregroundStyle(Deck.tertiary) }
                    else { Text(provider.id).font(.system(size: 12)).foregroundStyle(Deck.tertiary) }
                }
            }
            Spacer()
            if provider.executable != nil {
                Button("Sign in") { model.launch(provider, login: true) }.buttonStyle(DeckButtonStyle(kind: .secondary))
                Button("Open in Terminal") { model.launch(provider) }.buttonStyle(DeckButtonStyle(kind: .primary))
            }
        }
        .padding(.bottom, 4)
    }

    var addSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProviderIcon(id: provider.id, size: 40)
                Text("Add a \(provider.name) account").font(.system(size: 18, weight: .bold))
            }
            Text("Sign-in opens in Terminal in a separate home. Running sessions keep their account. General settings are copied; credentials stay separate.")
                .font(.system(size: 13)).foregroundStyle(Deck.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Account name", text: $newLabel).textFieldStyle(.roundedBorder).onSubmit { addAccount() }
            HStack {
                Button("Cancel") { showAdd = false }.buttonStyle(DeckButtonStyle(kind: .secondary)).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add and sign in") { addAccount() }.buttonStyle(DeckButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                    .disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24).frame(width: 440)
    }
    func addAccount() { showAdd = false; model.add(provider, label: newLabel); newLabel = "" }

    @ViewBuilder var accountsCard: some View {
        if let registry = model.registries[provider.id] {
            DeckCard {
                VStack(alignment: .leading, spacing: 14) {
                    CardTitle(text: "Accounts", trailing: "Applies to new sessions")
                    VStack(spacing: 0) {
                        ForEach(Array(registry.accounts.enumerated()), id: \.element.id) { index, account in
                            if index > 0 { Divider().overlay(Deck.divider) }
                            accountRow(account, registry: registry)
                        }
                    }
                    HStack(spacing: 12) {
                        Text("Automatic switching").font(.system(size: 13, weight: .medium)).foregroundStyle(Deck.text)
                        Toggle("Automatic switching", isOn: Binding(get: { registry.switch == "auto" }, set: { enabled in
                            model.perform { try model.accounts?.setMode(provider, auto: enabled, threshold: registry.threshold) }
                        })).labelsHidden().toggleStyle(.switch)
                        Spacer()
                        Stepper(value: Binding(get: { registry.threshold }, set: { value in
                            model.perform { try model.accounts?.setMode(provider, auto: registry.switch == "auto", threshold: value) }
                        }), in: 50...100) {
                            Text("Switch at \(registry.threshold)%").font(.system(size: 13, weight: .medium)).monospacedDigit()
                        }
                    }
                    .padding(12).background(Deck.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Text("Fresh accounts below the threshold are ranked by headroom, then reset time. Running sessions keep their login. When every account is exhausted the current one stays selected.")
                        .font(.system(size: 12)).foregroundStyle(Deck.tertiary).fixedSize(horizontal: false, vertical: true)
                    Button { showAdd = true } label: { Label("Add account", systemImage: "plus") }.buttonStyle(DeckButtonStyle(kind: .secondary))
                }
            }
        }
    }

    func accountRow(_ account: Account, registry: AccountRegistry) -> some View {
        let active = account.id == registry.active
        let data = record?.accounts.first { $0["id"].string == account.id }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: active ? "checkmark.circle.fill" : "circle").font(.system(size: 18))
                    .foregroundStyle(active ? Deck.accent : Deck.track)
                    .onTapGesture { if !active && !account.pendingLogin { model.perform { try model.accounts?.use(provider, id: account.id) } } }
                    .accessibilityLabel(active ? "Selected" : "Use \(account.label)")
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(account.label).font(.system(size: 14, weight: .semibold)).foregroundStyle(Deck.text)
                        if account.primary { Pill(text: "Primary") }
                        if account.pendingLogin { Pill(text: "Sign-in pending", foreground: Deck.warning, background: Deck.warningSoft) }
                    }
                    if let plan = data?["plan"].string, !plan.isEmpty { Text(plan).font(.system(size: 12)).foregroundStyle(Deck.secondary) }
                }
                Spacer()
                Menu {
                    Button("Use for new sessions") { model.perform { try model.accounts?.use(provider, id: account.id) } }.disabled(account.pendingLogin)
                    Button("Open in Terminal") { model.launch(provider, account: account.id) }.disabled(account.pendingLogin)
                    Button("Sign in / Reauthenticate") { model.launch(provider, account: account.id, login: true) }
                    Button("Rename…") { renameID = account.id; renameText = account.label }
                    if !account.primary {
                        Button("Copy settings from primary again") { model.perform { try model.accounts?.resyncSettings(provider, id: account.id) } }
                        Divider()
                        Button("Remove from list", role: .destructive) { model.perform { try model.accounts?.remove(provider, id: account.id) } }
                    }
                } label: { Image(systemName: "ellipsis").font(.system(size: 14, weight: .bold)).foregroundStyle(Deck.secondary) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Account actions")
            }
            if let data {
                let limits = data["limits"].array.compactMap(UsageLimit.init)
                HStack(spacing: 16) {
                    ForEach(limits) { limit in
                        let level = limit.level(at: Date())
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(limit.label).font(.system(size: 11)).foregroundStyle(Deck.secondary)
                                Spacer()
                                Text(Deck.percent(level)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            }
                            UsageBar(value: level, tint: Deck.tint(for: level, stale: data["stale"].bool), height: 6)
                        }
                    }
                }
                .padding(.leading, 28)
                if !data["usageStatusText"].string.isEmpty { Text(data["usageStatusText"].string).font(.system(size: 11)).foregroundStyle(Deck.tertiary).padding(.leading, 28) }
            }
        }
        .padding(.vertical, 12)
    }
}

// MARK: - Detail cards

struct LimitsCard: View {
    let record: UsageRecord
    var body: some View {
        DeckCard {
            VStack(alignment: .leading, spacing: 16) {
                CardTitle(text: "Usage limits", trailing: record.isStale ? "Previous data" : "")
                if record.limits.isEmpty {
                    Text("This provider reports no limit. Balances and local statistics appear below; no limit is inferred from token counts.")
                        .font(.system(size: 13)).foregroundStyle(Deck.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 20)], alignment: .leading, spacing: 20) {
                        ForEach(record.limits) { limit in
                            let level = limit.level(at: Date())
                            VStack(alignment: .leading, spacing: 8) {
                                Text(limit.label).font(.system(size: 13, weight: .medium)).foregroundStyle(Deck.secondary)
                                HStack(alignment: .lastTextBaseline) {
                                    Text(Deck.percent(level)).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                                        .foregroundStyle(Deck.tint(for: level, stale: record.isStale))
                                    Text("used").font(.system(size: 13)).foregroundStyle(Deck.tertiary)
                                    Spacer()
                                    if let reset = limit.resetsAt {
                                        Text(Deck.resetText(reset)).font(.system(size: 12, weight: .medium)).foregroundStyle(Deck.tertiary)
                                            .help(reset.formatted(date: .abbreviated, time: .shortened))
                                    }
                                }
                                UsageBar(value: level, tint: Deck.tint(for: level, stale: record.isStale), height: 10)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }
}

struct BalanceCard: View {
    let value: JSONValue
    var body: some View {
        let estimated = value["estimated"].bool
        let currency = value["currency"].string
        DeckCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    CardTitle(text: estimated ? "Balance · estimate" : "Balance")
                    if estimated { Pill(text: "Estimated", foreground: Deck.warning, background: Deck.warningSoft) }
                }
                if let remaining = value["remaining"].double {
                    Text(Deck.money(remaining, currency)).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Deck.text)
                    Text(estimated ? "remaining (estimated)" : "remaining").font(.system(size: 12)).foregroundStyle(Deck.tertiary)
                }
                HStack(spacing: 28) {
                    if let funded = value["funded"].double, funded > 0 { figure(estimated ? "Configured funding" : "Funded", Deck.money(funded, currency)) }
                    if let spent = value["spent"].double, spent > 0 || (value["funded"].double ?? 0) > 0 { figure(estimated ? "Rated spend" : "Spent", Deck.money(spent, currency)) }
                }
                if estimated {
                    Text("Calculated from the funding amount you configured minus rated usage — not a balance reported by the provider.")
                        .font(.system(size: 12)).foregroundStyle(Deck.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    func figure(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 15, weight: .semibold)).foregroundStyle(Deck.text)
            Text(name).font(.system(size: 12)).foregroundStyle(Deck.secondary)
        }
    }
}

struct StatsCard: View {
    let raw: JSONValue
    let title: String
    var body: some View {
        DeckCard {
            VStack(alignment: .leading, spacing: 14) {
                CardTitle(text: title)
                HStack(spacing: 10) {
                    tile("Tokens", raw["todayTotalTokens"].double)
                    tile("Prompts", raw["todayPrompts"].double)
                    tile("Sessions", raw["todaySessions"].double)
                    tile("Active days", raw["activeDays"].double)
                }
            }
        }
    }
    func tile(_ name: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(compact(value)).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(Deck.text).monospacedDigit()
            Text(name).font(.system(size: 12)).foregroundStyle(Deck.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Deck.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct ActivityCard: View {
    let raw: JSONValue
    var body: some View {
        let days = Array(raw["recentDays"].array.suffix(14))
        if !days.isEmpty {
            let values = days.map { $0["messageCount"].double ?? $0["prompts"].double ?? 0 }
            let peak = max(1, values.max() ?? 1)
            DeckCard {
                VStack(alignment: .leading, spacing: 14) {
                    CardTitle(text: "Daily activity", trailing: "messages")
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                            let value = values[index]
                            let last = index == days.count - 1
                            VStack(spacing: 6) {
                                Text(value == peak || last ? compact(value) : " ").font(.system(size: 10, weight: .semibold)).foregroundStyle(Deck.secondary)
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(last ? Deck.accent : Deck.accent.opacity(0.28))
                                    .frame(height: max(4, 110 * value / peak))
                                Text(weekday(day["date"].string)).font(.system(size: 11, weight: last ? .bold : .regular))
                                    .foregroundStyle(last ? Deck.text : Deck.tertiary)
                            }
                            .frame(maxWidth: .infinity)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(day["date"].string): \(Int(value)) messages")
                        }
                    }
                    .frame(height: 150, alignment: .bottom)
                }
            }
        }
    }
    func weekday(_ value: String) -> String {
        guard let date = dayParser.date(from: value) else { return value }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }
}

struct ModelsCard: View {
    let raw: JSONValue
    var body: some View {
        let models = raw["modelUsage"].object
        if !models.isEmpty {
            let totals = models.mapValues { b in b["totalTokens"].double ?? ((b["inputTokens"].double ?? 0) + (b["outputTokens"].double ?? 0)) }
            let peak = max(1, totals.values.max() ?? 1)
            DeckCard {
                VStack(alignment: .leading, spacing: 14) {
                    CardTitle(text: "Models", trailing: "recorded tokens")
                    ForEach(models.keys.sorted { (totals[$0] ?? 0) > (totals[$1] ?? 0) }, id: \.self) { name in
                        let bucket = models[name] ?? .null
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Deck.text).textSelection(.enabled)
                                Spacer()
                                Text(compact(totals[name])).font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                            }
                            UsageBar(value: (totals[name] ?? 0) / peak, tint: Deck.accent.opacity(0.75), height: 6)
                            Text(["inputTokens": "in", "outputTokens": "out", "cacheReadTokens": "cache read", "cacheWriteTokens": "cache write"]
                                .sorted { $0.key < $1.key }
                                .compactMap { key, label in bucket[key].double.map { "\(label) \(compact($0))" } }
                                .joined(separator: " · "))
                                .font(.system(size: 11)).foregroundStyle(Deck.tertiary)
                        }
                    }
                    Text("Local statistics reflect what each harness keeps on this Mac.").font(.system(size: 11)).foregroundStyle(Deck.tertiary)
                }
            }
        }
    }
}

// MARK: - Settings

struct SettingsPanel: View {
    @EnvironmentObject var model: DeckModel
    @State private var keyProvider = "deepseek"
    @State private var secret = ""
    @State private var loginAtLaunch = SMAppService.mainApp.status == .enabled
    @State private var message = ""
    @State private var integrationShell: IntegrationShell = .zsh
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("Refresh") {
                    Stepper(value: $model.settings.refreshInterval, in: 30...3600, step: 30) {
                        row("Refresh every", "\(model.settings.refreshInterval / 60) min \(model.settings.refreshInterval % 60) s")
                    }
                    note("Near a switching threshold: limits every 3 minutes. Network errors: retry after 30 seconds. Manual refresh bypasses caches.")
                    switchRow("Switch and exhaustion notifications", $model.settings.notifications)
                }
                section("macOS") {
                    switchRow("Launch at login", $loginAtLaunch).onChange(of: loginAtLaunch) { _, value in
                        model.perform { if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        loginAtLaunch = SMAppService.mainApp.status == .enabled
                    }
                    Picker("Terminal shell", selection: $integrationShell) {
                        ForEach(IntegrationShell.allCases) { shell in Text(shell.rawValue).tag(shell) }
                    }
                    HStack {
                        Button("Install shell integration") { model.perform { if let store = model.store { try ShellIntegration(store: store).install(cli: model.cli, shell: integrationShell) } } }
                            .buttonStyle(DeckButtonStyle(kind: .secondary))
                        Button("Remove") { model.perform { if let store = model.store { try ShellIntegration(store: store).uninstall(shell: integrationShell) } } }
                            .buttonStyle(DeckButtonStyle(kind: .plain))
                    }
                    note("Connects zsh, bash or fish to the selected account for new claude, codex and grok sessions. Shell startup files are backed up before changes. Open a new terminal after installing.")
                }
                section("Provider keys · macOS Keychain") {
                    Picker("Provider", selection: $keyProvider) {
                        ForEach(model.providers.filter { ProviderSecrets.variables[$0.id] != nil }) { Text($0.name).tag($0.id) }
                    }
                    SecureField("API key or token", text: $secret).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Save key") { model.perform { try ProviderSecrets.set(provider: keyProvider, secret: secret); secret = ""; message = "Saved in the macOS Keychain." } }
                            .buttonStyle(DeckButtonStyle(kind: .primary)).disabled(secret.isEmpty)
                        Button("Remove saved key") { model.perform { try ProviderSecrets.set(provider: keyProvider, secret: ""); message = "Removed the key AgentDeck saved." } }
                            .buttonStyle(DeckButtonStyle(kind: .secondary))
                    }
                    note("OAuth accounts sign in with their own CLI. Keys saved here add to existing CLI credentials and environment variables.")
                }
                .disabled(model.demo)
                section("Usage across devices (optional)") {
                    HStack {
                        TextField("Sync folder — empty keeps everything on this Mac", text: $model.settings.syncDirectory).textFieldStyle(.roundedBorder)
                        Button("Choose…") {
                            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
                            if panel.runModal() == .OK, let path = panel.url?.path { model.settings.syncDirectory = path }
                        }.buttonStyle(DeckButtonStyle(kind: .secondary))
                    }
                    note("Only usage statistics are exported. Sign-ins, account details and conversations never leave this Mac.")
                }
                section("Collectors") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                        ForEach(model.providers) { provider in
                            Toggle(isOn: Binding(get: { !model.settings.disabledProviders.contains(provider.id) }, set: { enabled in
                                model.settings.disabledProviders.removeAll { $0 == provider.id }
                                if !enabled { model.settings.disabledProviders.append(provider.id) }
                            })) {
                                HStack(spacing: 8) { ProviderIcon(id: provider.id, size: 20); Text(provider.name).font(.system(size: 13)) }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                section("Diagnostics") {
                    HStack {
                        Button("Copy redacted diagnostics") {
                            let failed = model.records.filter { $0.raw["collectorFailed"].bool }.map(\.id).joined(separator: ", ")
                            let text = "AgentDeck \(AgentDeckVersion.current)\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nCollectors: \(model.providers.count)\nCached: \(model.records.count)\nFailed collectors: \(failed)"
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); message = "Diagnostics copied."
                        }.buttonStyle(DeckButtonStyle(kind: .secondary))
                        if !message.isEmpty { Text(message).font(.system(size: 12)).foregroundStyle(Deck.success) }
                    }
                    note("Contains version, macOS version and collector counts only — no credentials, accounts or transcripts.")
                }
            }
            .padding(20)
        }
        .background(Deck.background)
        .frame(width: 620, height: 720)
        .onChange(of: model.settings.refreshInterval) { _, _ in model.saveSettings() }
        .onChange(of: model.settings.notifications) { _, _ in model.saveSettings() }
        .onChange(of: model.settings.syncDirectory) { _, _ in model.saveSettings() }
        .onChange(of: model.settings.disabledProviders) { _, _ in model.saveSettings() }
    }
    func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        DeckCard {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(text: title)
                content()
            }
            .font(.system(size: 13))
        }
    }
    func switchRow(_ name: String, _ value: Binding<Bool>) -> some View {
        HStack { Text(name).foregroundStyle(Deck.text); Spacer(); Toggle(name, isOn: value).labelsHidden().toggleStyle(.switch) }
    }
    func row(_ name: String, _ value: String) -> some View {
        HStack { Text(name).foregroundStyle(Deck.text); Spacer(); Text(value).foregroundStyle(Deck.secondary).monospacedDigit() }
    }
    func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Deck.tertiary).fixedSize(horizontal: false, vertical: true)
    }
}
