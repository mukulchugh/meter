import Foundation
import MeterCore
import Observation

public enum SidebarItem: String, CaseIterable, Identifiable, Sendable {
    case overview, people, keys, models, budgets, connections, export
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .overview: "Overview"
        case .people: "People"
        case .keys: "Keys & Projects"
        case .models: "Models"
        case .budgets: "Budgets & Alerts"
        case .connections: "Connections"
        case .export: "Export"
        }
    }
    public var symbol: String {
        switch self {
        case .overview: "chart.bar.xaxis"
        case .people: "person.2"
        case .keys: "key"
        case .models: "cpu"
        case .budgets: "gauge.with.needle"
        case .connections: "link"
        case .export: "square.and.arrow.up"
        }
    }
}

public enum Surface: Hashable, Sendable { case popover, window }

public enum SettingKey {
    public static let menuMetric = "ui.menu_metric"
    public static let scope = "ui.scope"
    public static let backgroundPoll = "poll.background"
    public static let dismissedSuggestions = "tags.dismissed"
    public static let alertsEnabled = "alerts.enabled"
    /// "1" while the sample-data preview is on. The one thing preview writes to the real store.
    public static let previewSampleData = "preview.sample_data"
    static func lastKnown(_ metric: MenuMetric, _ scope: Scope) -> String { "ui.last_known.\(metric.rawValue).\(scope.raw)" }
}

/// The one observable the scenes share. It owns the store, the secret store and the sync engine, and holds
/// the latest immutable snapshot. All numbers come from MeterCore queries over that snapshot.
@Observable @MainActor
public final class AppModel {
    // Dependencies. `store`, `secrets` and `engine` are the active set: the real ones, or the in-memory
    // sample set while the preview is on. Nothing in the preview ever touches the real set.
    public private(set) var store: MeterStore
    public private(set) var secrets: any Secrets
    public private(set) var engine: SyncEngine
    private let realStore: MeterStore
    private let realSecrets: any Secrets
    private let realEngine: SyncEngine
    private let notifier: any Notifying
    private let loginItem: any LoginItemControlling
    private let clock: @Sendable () -> Date
    public let isDemo: Bool
    private let seedDemo: Bool

    // State the views read
    public private(set) var snapshot = MeterSnapshot()
    public private(set) var now: Date
    public private(set) var popover: PopoverContent
    public private(set) var isRefreshing = false
    public private(set) var isLoaded = false
    public private(set) var message: String?
    public private(set) var startupNote: String?
    public private(set) var menuMetric: MenuMetric = .today
    public private(set) var scope: Scope = .all
    public private(set) var backgroundMinutes = 15
    public private(set) var launchAtLogin = false
    public private(set) var dismissedSuggestions = Set<String>()
    public private(set) var alertsEnabled = false
    /// True while the sample-data preview is showing instead of real data.
    public private(set) var isPreviewing = false
    /// True when at least one real organization is connected (preview is then not offered).
    public private(set) var hasRealOrgs = false
    /// Set by "Add organization" in an empty state; the Connections screen opens its form and clears it.
    public var addOrganizationRequested = false
    public var selection: SidebarItem = .overview

    private var lastKnown = [String: Decimal]()
    private var surfaces = Set<Surface>()
    private var started = false
    private var timer: Task<Void, Never>?

    public init(store: MeterStore, secrets: any Secrets, engine: SyncEngine, notifier: any Notifying = NoopNotifier(),
                loginItem: any LoginItemControlling = NoopLoginItem(), clock: @escaping @Sendable () -> Date = { Date() },
                isDemo: Bool = false, seedDemo: Bool = false, startupNote: String? = nil) {
        self.store = store
        self.secrets = secrets
        self.engine = engine
        self.realStore = store
        self.realSecrets = secrets
        self.realEngine = engine
        self.notifier = notifier
        self.loginItem = loginItem
        self.clock = clock
        self.isDemo = isDemo
        self.seedDemo = seedDemo
        self.startupNote = startupNote
        let t = clock()
        now = t
        popover = PopoverContent(snapshot: MeterSnapshot(), now: t, scope: .all)
    }

    /// Builds the model the app runs with. `METER_DEMO=1` gives an in-memory, fake-provider model.
    public static func bootstrap(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppModel {
        if environment["METER_DEMO"] == "1" {
            let t = Date()
            // swiftlint:disable:next force_try
            let store = try! MeterStore.inMemory()
            let secrets = InMemorySecrets()
            let engine = SyncEngine(store: store, secrets: secrets, clientFactory: DemoData.factory(now: t))
            return AppModel(store: store, secrets: secrets, engine: engine, notifier: NoopNotifier(),
                            loginItem: NoopLoginItem(), isDemo: true, seedDemo: true)
        }
        let secrets = KeychainSecrets()
        let store: MeterStore
        var note: String?
        do { store = try MeterStore.openDefault(environment: environment) } catch {
            // Keep the app usable and say why nothing is saved.
            // swiftlint:disable:next force_try
            store = try! MeterStore.inMemory()
            note = "Meter could not open its database (\(error)). Changes will not be saved."
        }
        let engine = SyncEngine(store: store, secrets: secrets)
        return AppModel(store: store, secrets: secrets, engine: engine, notifier: SystemNotifier(),
                        loginItem: SystemLoginItem(), startupNote: note)
    }

    // MARK: Lifecycle

    /// Loads settings and the first snapshot. Safe to call more than once.
    public func load() async {
        if seedDemo && !isLoaded {
            try? await DemoData.seed(store: store, secrets: secrets, engine: engine, now: now)
        }
        await loadSettings()
        if !isDemo, (try? await realStore.setting(SettingKey.previewSampleData)) == "1" {
            // A saved preview choice only holds while no real organization exists.
            if await realOrgsExist() { try? await realStore.setSetting(SettingKey.previewSampleData, "0") } else { await activatePreview() }
        }
        launchAtLogin = loginItem.isEnabled
        await reload()
        isLoaded = true
    }

    /// Starts background sync and the 60 s UI timer.
    public func start() async {
        guard !started else { return }
        started = true
        await load()
        await realEngine.setBackgroundLegacyInterval(TimeInterval(backgroundMinutes * 60))
        await realEngine.setForeground(!surfaces.isEmpty)
        await realEngine.start()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.reload()
            }
        }
    }

    public func stop() async {
        timer?.cancel()
        timer = nil
        await realEngine.stop()
        started = false
    }

    /// Window or popover visibility drives foreground polling.
    public func surface(_ s: Surface, visible: Bool) {
        if visible { surfaces.insert(s) } else { surfaces.remove(s) }
        let foreground = !surfaces.isEmpty
        Task { await realEngine.setForeground(foreground) }
        if visible { Task { await reload() } }
    }

    public var isForeground: Bool { !surfaces.isEmpty }

    private func loadSettings() async {
        if let v = try? await realStore.setting(SettingKey.menuMetric), let m = MenuMetric(rawValue: v) { menuMetric = m }
        if let v = try? await store.setting(SettingKey.scope) { scope = Scope(raw: v) }
        if let v = try? await realStore.setting(SettingKey.backgroundPoll), let s = Int(v) {
            backgroundMinutes = [15, 30, 60].min { abs($0 - s / 60) < abs($1 - s / 60) } ?? 15
        }
        let dismissed = (try? await store.setting(SettingKey.dismissedSuggestions)) ?? nil
        dismissedSuggestions = Set((dismissed ?? "").split(separator: "\n").map(String.init))
        alertsEnabled = (try? await realStore.setting(SettingKey.alertsEnabled)) == "1"
    }

    // MARK: Refresh

    public func reload() async {
        do {
            snapshot = try await store.snapshot()
        } catch {
            message = "Could not read the local database: \(error)"
            return
        }
        now = clock()
        hasRealOrgs = isPreviewing ? await realOrgsExist() : !snapshot.orgs.isEmpty
        if scope != .all, case .org(let id) = scope, snapshot.org(id) == nil { scope = .all }
        await recordLastKnown()
        rebuildPopover()
        await evaluateAlerts()
    }

    public func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        _ = await engine.refreshAll()
        await reload()
        isRefreshing = false
    }

    private func recordLastKnown() async {
        for metric in [MenuMetric.today, .mtd] {
            let r = metric == .mtd ? snapshot.monthToDate(now: now, filter: scope.filter) : snapshot.today(now: now, filter: scope.filter)
            let key = SettingKey.lastKnown(metric, scope)
            if r.state == .value || r.state == .noActivity, let a = r.amount {
                lastKnown[key] = a
                try? await store.setSetting(key, Money.string(a))
            } else if lastKnown[key] == nil, let v = try? await store.setting(key) {
                lastKnown[key] = Money.decimal(from: v)
            }
        }
    }

    private func rebuildPopover() {
        popover = PopoverContent(snapshot: snapshot, now: now, scope: scope, metric: menuMetric,
                                 lastKnown: lastKnown[SettingKey.lastKnown(menuMetric == .mtd ? .mtd : .today, scope)])
    }

    // MARK: Settings

    public func setMenuMetric(_ m: MenuMetric) {
        menuMetric = m
        rebuildPopover()
        Task { try? await realStore.setSetting(SettingKey.menuMetric, m.rawValue) }
    }

    public func setScope(_ s: Scope) async {
        scope = s
        try? await store.setSetting(SettingKey.scope, s.raw)
        await reload()
    }

    public func setBackgroundMinutes(_ m: Int) async {
        backgroundMinutes = m
        try? await realStore.setSetting(SettingKey.backgroundPoll, String(m * 60))
        await realEngine.setBackgroundLegacyInterval(TimeInterval(m * 60))
    }

    public func setLaunchAtLogin(_ on: Bool) {
        do {
            try loginItem.setEnabled(on)
            launchAtLogin = loginItem.isEnabled
        } catch {
            launchAtLogin = loginItem.isEnabled
            message = "Could not change launch at login: \(error.localizedDescription)"
        }
    }

    public func dismissMessage() { message = nil }

    // MARK: Tags

    public func setTag(orgId: String, target: TagTarget, targetId: String, kind: TagKind) async {
        do { try await store.setTag(Tag(orgId: orgId, target: target, targetId: targetId, kind: kind)) }
        catch { message = "Could not save the tag: \(error)" }
        await reload()
    }

    public func accept(_ s: TagSuggestion) async {
        await setTag(orgId: s.orgId, target: s.target, targetId: s.targetId, kind: s.suggested)
    }

    public func dismiss(_ s: TagSuggestion) async {
        dismissedSuggestions.insert(KeysContent.suggestionId(s))
        try? await store.setSetting(SettingKey.dismissedSuggestions, dismissedSuggestions.sorted().joined(separator: "\n"))
    }

    // MARK: Budgets and prepaid

    /// Saves a budget. The first budget ever created asks for notification permission.
    @discardableResult
    public func saveBudget(_ draft: BudgetDraft) async -> BudgetFormErrors? {
        switch draft.validate() {
        case .failure(let e): return e
        case .success(let budget):
            let first = ((try? await store.budgets()) ?? []).isEmpty
            do { try await store.upsertBudget(budget) } catch {
                message = "Could not save the budget: \(error)"
                return nil
            }
            if first && !alertsEnabled && !isPreviewing {
                let granted = await notifier.requestAuthorization()
                alertsEnabled = granted
                try? await store.setSetting(SettingKey.alertsEnabled, granted ? "1" : "0")
            }
            await reload()
            return nil
        }
    }

    public func deleteBudget(id: String) async {
        try? await store.deleteBudget(id: id)
        await reload()
    }

    public func setPrepaid(orgId: String, amount: Decimal, enteredAt: Date) async {
        try? await store.setPrepaid(PrepaidBalance(orgId: orgId, amount: amount, enteredAt: enteredAt))
        await reload()
    }

    private func evaluateAlerts() async {
        guard alertsEnabled, !isPreviewing else { return }
        for event in AlertPlanner.candidates(snapshot: snapshot, now: now) {
            let key = AlertPlanner.settingKey(for: event)
            if (try? await store.setting(key)) != nil { continue }
            try? await store.setSetting(key, "1")
            await notifier.post(event)
        }
    }

    // MARK: Connections

    /// Writes the key to the secret store (never the database), saves the org, runs a first refresh.
    public func addOrganization(_ draft: ConnectionDraft) async -> ConnectionResult? {
        guard draft.isValid else { return nil }
        if isPreviewing { await exitPreview() }
        let org = Org(id: UUID().uuidString, provider: draft.provider, displayName: draft.trimmedName)
        do {
            try secrets.write(draft.trimmedKey, for: org.keychainRef)
            try await store.upsertOrg(org)
        } catch {
            try? secrets.delete(org.keychainRef)
            return ConnectionResult(orgId: org.id, state: .error, message: "Could not save the key: \(error)", succeeded: false)
        }
        return await firstRefresh(org)
    }

    /// Replaces the stored key for an org and refreshes it.
    public func rotateKey(orgId: String, newKey: String) async -> ConnectionResult? {
        guard let org = snapshot.org(orgId) else { return nil }
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix(ConnectionHelp.keyPrefix(for: org.provider)) else {
            return ConnectionResult(orgId: orgId, state: .error,
                                    message: "\(org.provider.displayName) admin keys start with \(ConnectionHelp.keyPrefix(for: org.provider)).",
                                    succeeded: false)
        }
        do { try secrets.write(key, for: org.keychainRef) } catch {
            return ConnectionResult(orgId: orgId, state: .error, message: "Could not save the key: \(error)", succeeded: false)
        }
        return await firstRefresh(org)
    }

    public func removeOrganization(id: String) async {
        guard let org = snapshot.org(id) else { return }
        try? secrets.delete(org.keychainRef)
        try? await store.removeOrg(id: id)
        if scope == .org(id) { await setScope(.all) } else { await reload() }
    }

    private func firstRefresh(_ org: Org) async -> ConnectionResult {
        isRefreshing = true
        let report = await engine.refresh(org: org)
        await reload()
        isRefreshing = false
        let state = snapshot.coverageSummary(now: now).orgs.first { $0.org.id == org.id }?.state ?? .connected
        var failure: ProviderError?
        var lines = 0
        for outcome in report.outcomes.values {
            switch outcome {
            case .failed(let e): if failure == nil || e.kind == "auth" { failure = e }
            case .updated(let n): lines += n
            case .backedOff, .skipped: break
            }
        }
        if let failure {
            return ConnectionResult(orgId: org.id, state: state, message: failure.message, succeeded: false)
        }
        return ConnectionResult(orgId: org.id, state: state, message: "Connected. Loaded \(Fmt.count(lines)) rows.", succeeded: true)
    }

    // MARK: Sample-data preview

    /// The banner text while previewing, nil otherwise. Both the popover and the window show it.
    public var previewBanner: PreviewBanner? { isPreviewing ? PreviewBanner() : nil }

    /// Whether the preview can be turned on: only before any real organization is connected.
    public var canPreview: Bool { !isDemo && (isPreviewing || !hasRealOrgs) }

    /// "Add organization" from any empty state: open Connections with the add form showing.
    public func beginAddOrganization() {
        selection = .connections
        addOrganizationRequested = true
    }

    public func setPreview(_ on: Bool) async {
        if on { await enterPreview() } else { await exitPreview() }
    }

    /// Switches every screen to an in-memory sample company and remembers the choice. Does nothing when a
    /// real organization exists, so sample and real data never mix.
    public func enterPreview() async {
        guard !isDemo, !isPreviewing else { return }
        guard !(await realOrgsExist()) else { return }
        await activatePreview()
        try? await realStore.setSetting(SettingKey.previewSampleData, "1")
        await reload()
    }

    /// Back to the real (empty or connected) data. The sample store is discarded.
    public func exitPreview() async {
        guard isPreviewing else { return }
        let sampleEngine = engine
        await sampleEngine.stop()
        store = realStore
        secrets = realSecrets
        engine = realEngine
        isPreviewing = false
        try? await realStore.setSetting(SettingKey.previewSampleData, "0")
        scope = .all
        await loadSettings()
        await reload()
    }

    private func realOrgsExist() async -> Bool { ((try? await realStore.orgs()) ?? []).isEmpty == false }

    /// Builds a fresh in-memory sample set and makes it the active one. Never touches the real set.
    private func activatePreview() async {
        let t = clock()
        guard let sampleStore = try? MeterStore.inMemory() else { return }
        let sampleSecrets = InMemorySecrets()
        let sampleEngine = SyncEngine(store: sampleStore, secrets: sampleSecrets, clientFactory: SampleData.factory(now: t), now: clock)
        do { try await SampleData.seed(store: sampleStore, secrets: sampleSecrets, engine: sampleEngine, now: t) } catch {
            message = "Could not build the sample data: \(error)"
            return
        }
        store = sampleStore
        secrets = sampleSecrets
        engine = sampleEngine
        isPreviewing = true
        scope = .all
        await loadSettings()
    }

    // MARK: Export

    public func csv(from: UTCDay, to: UTCDay) -> String { Export.csv(snapshot, from: from, to: to) }

    public func weeklySummary() -> String { Export.weeklySummary(snapshot, now: now) }

    public func csvFileName(from: UTCDay, to: UTCDay) -> String { "meter-\(from.string)-to-\(to.string).csv" }

    public var weeklyFileName: String { "meter-weekly-\(UTCDay(now).string).md" }
}

/// The persistent notice shown in the popover and the window while sample data is on.
public struct PreviewBanner: Equatable, Sendable {
    public let text = "Sample data. Not your spend."
    public let exitTitle = "Exit preview"
    public init() {}
}
