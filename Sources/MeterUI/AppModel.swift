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
    static func lastKnown(_ metric: MenuMetric, _ scope: Scope) -> String { "ui.last_known.\(metric.rawValue).\(scope.raw)" }
}

/// The one observable the scenes share. It owns the store, the secret store and the sync engine, and holds
/// the latest immutable snapshot. All numbers come from MeterCore queries over that snapshot.
@Observable @MainActor
public final class AppModel {
    // Dependencies
    public let store: MeterStore
    public let secrets: any Secrets
    public let engine: SyncEngine
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
        launchAtLogin = loginItem.isEnabled
        await reload()
        isLoaded = true
    }

    /// Starts background sync and the 60 s UI timer.
    public func start() async {
        guard !started else { return }
        started = true
        await load()
        await engine.setBackgroundLegacyInterval(TimeInterval(backgroundMinutes * 60))
        await engine.setForeground(!surfaces.isEmpty)
        await engine.start()
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
        await engine.stop()
        started = false
    }

    /// Window or popover visibility drives foreground polling.
    public func surface(_ s: Surface, visible: Bool) {
        if visible { surfaces.insert(s) } else { surfaces.remove(s) }
        let foreground = !surfaces.isEmpty
        Task { await engine.setForeground(foreground) }
        if visible { Task { await reload() } }
    }

    public var isForeground: Bool { !surfaces.isEmpty }

    private func loadSettings() async {
        if let v = try? await store.setting(SettingKey.menuMetric), let m = MenuMetric(rawValue: v) { menuMetric = m }
        if let v = try? await store.setting(SettingKey.scope) { scope = Scope(raw: v) }
        if let v = try? await store.setting(SettingKey.backgroundPoll), let s = Int(v) {
            backgroundMinutes = [15, 30, 60].min { abs($0 - s / 60) < abs($1 - s / 60) } ?? 15
        }
        if let v = try? await store.setting(SettingKey.dismissedSuggestions) {
            dismissedSuggestions = Set(v.split(separator: "\n").map(String.init))
        }
        alertsEnabled = (try? await store.setting(SettingKey.alertsEnabled)) == "1"
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
        Task { try? await store.setSetting(SettingKey.menuMetric, m.rawValue) }
    }

    public func setScope(_ s: Scope) async {
        scope = s
        try? await store.setSetting(SettingKey.scope, s.raw)
        await reload()
    }

    public func setBackgroundMinutes(_ m: Int) async {
        backgroundMinutes = m
        try? await store.setSetting(SettingKey.backgroundPoll, String(m * 60))
        await engine.setBackgroundLegacyInterval(TimeInterval(m * 60))
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
            if first && !alertsEnabled {
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
        guard alertsEnabled else { return }
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

    // MARK: Export

    public func csv(from: UTCDay, to: UTCDay) -> String { Export.csv(snapshot, from: from, to: to) }

    public func weeklySummary() -> String { Export.weeklySummary(snapshot, now: now) }

    public func csvFileName(from: UTCDay, to: UTCDay) -> String { "meter-\(from.string)-to-\(to.string).csv" }

    public var weeklyFileName: String { "meter-weekly-\(UTCDay(now).string).md" }
}
