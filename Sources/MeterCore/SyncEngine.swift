import Foundation

public struct SyncConfig: Sendable {
    /// How often the background loop wakes to look for due work.
    public var tick: TimeInterval = 30
    /// Anthropic legacy "today" feed while the UI is visible: at most once a minute (RESEARCH.md section 4).
    public var foregroundLegacyInterval: TimeInterval = 60
    /// The same feed otherwise: configurable 15 to 60 minutes.
    public var backgroundLegacyInterval: TimeInterval = 15 * 60
    public var analyticsInterval: TimeInterval = 3600
    /// OpenAI costs: hourly.
    public var openAIInterval: TimeInterval = 3600
    public var claudeCodeInterval: TimeInterval = 3600
    public var limitsInterval: TimeInterval = 3600
    /// Names refresh daily.
    public var entitiesInterval: TimeInterval = 86_400
    /// Providers restate recent days, so this many trailing days are refetched on every sync.
    public var trailingDays = 3
    public var anthropicBackfillDays = 365
    public var openAIBackfillDays = 365
    /// Claude Code is one call per day, so the first sync is shorter.
    public var claudeCodeBackfillDays = 30
    /// Days the legacy feed covers while the analytics feed is healthy.
    public var legacyWindowDays = 3
    public var baseBackoff: TimeInterval = 60
    public var maxBackoff: TimeInterval = 3600
    /// The analytics endpoint cannot look before this date (RESEARCH.md section 2.1).
    public var analyticsFloor = UTCDay(year: 2026, month: 1, day: 1)

    public init() {}
}

public enum SyncOutcome: Sendable, Equatable {
    case updated(lines: Int)
    case backedOff(until: Date)
    case skipped(String)
    case failed(ProviderError)
}

public struct RefreshReport: Sendable, Equatable {
    public var orgId: String
    public var outcomes: [SyncSource: SyncOutcome]
}

/// Polls each org's provider, upserts lines, and keeps coverage honest. An actor, so refreshes from the
/// UI and from the background loop never overlap.
public actor SyncEngine {
    private let store: MeterStore
    private let secrets: any Secrets
    private let factory: ProviderClientFactory
    private let now: @Sendable () -> Date
    public var config: SyncConfig

    private var foreground = false
    private var loop: Task<Void, Never>?
    private var blocked = [String: (until: Date, failures: Int)]()
    private var failures = [String: Int]()
    private var lastAttempt = [String: Date]()

    public init(store: MeterStore, secrets: any Secrets, clientFactory: @escaping ProviderClientFactory = defaultClientFactory(),
                config: SyncConfig = SyncConfig(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.secrets = secrets
        self.factory = clientFactory
        self.config = config
        self.now = now
    }

    // MARK: Control

    /// Foreground means a Meter window or popover is visible: the legacy feed polls every minute.
    public func setForeground(_ on: Bool) { foreground = on }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.syncDue()
                let tick = await self.config.tick
                try? await Task.sleep(for: .seconds(tick))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Refreshes every source for one org now, ignoring cadence but not a rate-limit backoff.
    public func refresh(org: Org) async -> RefreshReport {
        await run(org: org, only: nil)
    }

    public func refreshAll() async -> [RefreshReport] {
        var out = [RefreshReport]()
        for org in (try? await store.orgs()) ?? [] { out.append(await refresh(org: org)) }
        return out
    }

    /// One pass of the background loop: only sources whose interval has elapsed.
    public func syncDue() async {
        for org in (try? await store.orgs()) ?? [] { _ = await run(org: org, only: Set(await dueSources(org))) }
    }

    // MARK: Scheduling

    static func sources(for provider: Provider) -> [SyncSource] {
        switch provider {
        case .anthropic: [.anthropicAnalytics, .anthropicLegacy, .claudeCode, .entities]
        // Names before limits: project limits need the project list.
        case .openai: [.openaiCosts, .openaiCostsByUser, .entities, .limits]
        }
    }

    private func interval(_ s: SyncSource) -> TimeInterval {
        switch s {
        case .anthropicLegacy: foreground ? config.foregroundLegacyInterval : config.backgroundLegacyInterval
        case .anthropicAnalytics: config.analyticsInterval
        case .openaiCosts, .openaiCostsByUser: config.openAIInterval
        case .claudeCode: config.claudeCodeInterval
        case .limits: config.limitsInterval
        case .entities: config.entitiesInterval
        }
    }

    private func key(_ org: Org, _ s: SyncSource) -> String { "\(org.id)|\(s.rawValue)" }

    private func dueSources(_ org: Org) async -> [SyncSource] {
        var due = [SyncSource]()
        for s in Self.sources(for: org.provider) {
            let persisted = (try? await store.coverage(orgId: org.id, source: s))?.lastAttempt
            if let last = lastAttempt[key(org, s)] ?? persisted, now().timeIntervalSince(last) < interval(s) { continue }
            due.append(s)
        }
        return due
    }

    // MARK: Running

    private func run(org: Org, only: Set<SyncSource>?) async -> RefreshReport {
        var outcomes = [SyncSource: SyncOutcome]()
        let wanted = Self.sources(for: org.provider).filter { only?.contains($0) ?? true }
        guard !wanted.isEmpty else { return RefreshReport(orgId: org.id, outcomes: [:]) }

        let secret: String?
        do { secret = try secrets.read(org.keychainRef) } catch { secret = nil }
        guard let secret, !secret.isEmpty else {
            let err = ProviderError.auth(.noKey, org.provider)
            for s in wanted { outcomes[s] = .failed(err); await recordFailure(org, s, err) }
            return RefreshReport(orgId: org.id, outcomes: outcomes)
        }
        let client = factory(org, secret)
        var authFailed = false
        for s in wanted {
            if authFailed { outcomes[s] = .skipped("credential rejected"); continue }
            let k = key(org, s)
            if let b = blocked[k], b.until > now() { outcomes[s] = .backedOff(until: b.until); continue }
            lastAttempt[k] = now()
            do {
                let n = try await perform(s, org: org, client: client)
                blocked[k] = nil
                failures[k] = nil
                outcomes[s] = .updated(lines: n)
            } catch {
                let e = (error as? ProviderError) ?? .unexpectedResponse("\(error)")
                outcomes[s] = .failed(e)
                await recordFailure(org, s, e)
                if e.isAuth { authFailed = true }
                registerBackoff(k, e)
            }
        }
        return RefreshReport(orgId: org.id, outcomes: outcomes)
    }

    /// Only rate limits and server errors block further calls. Auth and network errors wait for the cadence.
    private func registerBackoff(_ k: String, _ e: ProviderError) {
        let n = (failures[k] ?? 0) + 1
        failures[k] = n
        let exp = min(config.baseBackoff * pow(2, Double(n - 1)), config.maxBackoff)
        switch e {
        case .rateLimited(let after): blocked[k] = (now().addingTimeInterval(after ?? exp), n)
        case .server: blocked[k] = (now().addingTimeInterval(exp), n)
        default: break
        }
    }

    private func recordFailure(_ org: Org, _ s: SyncSource, _ e: ProviderError) async {
        await update(org, s) { c in
            c.lastAttempt = self.now()
            c.lastError = e.message
            c.errorKind = e.kind
            // The beta analytics endpoint or the per-user pass being refused is a missing dimension, not an outage.
            if (s == .anthropicAnalytics || s == .openaiCostsByUser), case .badRequest = e { c.unavailable = true }
            if (s == .anthropicAnalytics || s == .openaiCostsByUser), case .notFound = e { c.unavailable = true }
        }
    }

    private func update(_ org: Org, _ s: SyncSource, _ change: (inout Coverage) -> Void) async {
        var c = (try? await store.coverage(orgId: org.id, source: s)) ?? Coverage(orgId: org.id, source: s)
        change(&c)
        try? await store.saveCoverage(c)
    }

    private func succeed(_ org: Org, _ s: SyncSource, watermark: Date? = nil, coveredThrough: UTCDay? = nil,
                         empty: Bool = false, note: String? = nil) async {
        await update(org, s) { c in
            c.lastAttempt = self.now()
            c.lastSuccess = self.now()
            c.watermark = watermark
            if let coveredThrough { c.coveredThrough = coveredThrough }
            c.lastError = nil
            c.errorKind = nil
            c.unavailable = false
            c.lastFetchEmpty = empty
            c.note = note
        }
    }

    private func perform(_ s: SyncSource, org: Org, client: any ProviderClient) async throws -> Int {
        let today = UTCDay(now())
        switch s {
        case .anthropicAnalytics: return try await syncAnalytics(org, client, today)
        case .anthropicLegacy: return try await syncLegacy(org, client, today)
        case .openaiCosts: return try await syncOpenAI(org, client, today, supplemental: false)
        case .openaiCostsByUser: return try await syncOpenAI(org, client, today, supplemental: true)
        case .claudeCode: return try await syncClaudeCode(org, client, today)
        case .entities:
            let e = try await client.fetchEntities()
            try await store.upsertEntities(e)
            await succeed(org, .entities)
            return e.count
        case .limits:
            guard let projects = try? await store.entities().filter({ $0.orgId == org.id && $0.kind == .project && !$0.archived }) else { return 0 }
            guard let limits = try await client.fetchLimits(projectIds: projects.map(\.id)) else { return 0 }
            try await store.replaceLimits(orgId: org.id, with: limits)
            await succeed(org, .limits)
            return limits.count
        }
    }

    /// Where a sync starts: the first sync backfills; later ones refetch the trailing days.
    private func start(covered: UTCDay?, today: UTCDay, backfill: Int) -> UTCDay {
        if let covered { return covered.adding(-(config.trailingDays - 1)) }
        return today.adding(-(backfill - 1))
    }

    private func windows(from: UTCDay, to: UTCDay, size: Int) -> [(UTCDay, UTCDay)] {
        var out = [(UTCDay, UTCDay)]()
        var a = from
        while a <= to {
            let b = min(a.adding(size - 1), to)
            out.append((a, b))
            a = b.adding(1)
        }
        return out
    }

    // MARK: Anthropic

    /// A day is complete once its end is at or before `data_refreshed_at` (RESEARCH.md section 8, "Current
    /// day"). Partial days are not stored: the legacy feed supplies them, so nothing is counted twice.
    private func syncAnalytics(_ org: Org, _ client: any ProviderClient, _ today: UTCDay) async throws -> Int {
        let cov = try await store.coverage(orgId: org.id, source: .anthropicAnalytics)
        var from = start(covered: cov.coveredThrough, today: today, backfill: config.anthropicBackfillDays)
        from = max(from, config.analyticsFloor)
        var stored = 0, anyLines = false
        var watermark: Date?
        var covered = cov.coveredThrough
        for (a, b) in windows(from: from, to: today, size: client.maxCostWindowDays) {
            let fetch = try await client.fetchCosts(from: a, to: b)
            if let w = fetch.watermark { watermark = watermark.map { min($0, w) } ?? w }
            let complete = fetch.watermark.map { UTCDay($0).adding(-1) } ?? today.adding(-1)
            let upTo = min(b, complete)
            guard upTo >= a else { continue }
            let lines = fetch.lines.filter { $0.day <= upTo }
            try await store.replaceCostLines(orgId: org.id, feed: .anthropicAnalytics, from: a, to: upTo, with: lines)
            anyLines = anyLines || !lines.isEmpty
            stored += lines.count
            covered = max(covered ?? upTo, upTo)
            await update(org, .anthropicAnalytics) { $0.coveredFrom = $0.coveredFrom ?? a; $0.coveredThrough = covered }
        }
        if let covered {
            try await store.deleteCostLines(orgId: org.id, feed: .anthropicLegacy, from: UTCDay(daysSinceEpoch: 0), to: covered)
        }
        await succeed(org, .anthropicAnalytics, watermark: watermark, coveredThrough: covered, empty: !anyLines)
        return stored
    }

    /// Fills the days after the analytics watermark, so the two feeds abut and nothing is counted twice:
    /// the window starts the day after analytics coverage ends (at most 60 days back) and never rewrites
    /// a day analytics holds, even if analytics later became unavailable.
    private func syncLegacy(_ org: Org, _ client: any ProviderClient, _ today: UTCDay) async throws -> Int {
        let analytics = try await store.coverage(orgId: org.id, source: .anthropicAnalytics)
        let cov = try await store.coverage(orgId: org.id, source: .anthropicLegacy)
        let analyticsOnly = analytics.coveredThrough == nil && analytics.unavailable
        let from: UTCDay
        if let through = analytics.coveredThrough {
            from = max(through.adding(1), today.adding(-59))
        } else if analyticsOnly {
            // The beta feed never worked, so the legacy feed is the only history: it backfills.
            from = start(covered: cov.coveredThrough, today: today, backfill: config.anthropicBackfillDays)
        } else {
            from = today.adding(-(config.legacyWindowDays - 1))
        }
        guard from <= today else { return 0 }
        guard let fetch = try await client.fetchRecentCosts(from: from, to: today) else { return 0 }
        let lines = fetch.lines.filter { $0.day >= from }
        try await store.replaceCostLines(orgId: org.id, feed: .anthropicLegacy, from: from, to: today, with: lines)
        // Lines before `from` may linger from an earlier pass until analytics deletes them; they are
        // still legacy-covered only when the span is unbroken, so an incremental backfill keeps its start.
        let keepStart = analyticsOnly && cov.coveredFrom != nil && (cov.coveredThrough.map { $0 >= from.adding(-1) } ?? false)
        await update(org, .anthropicLegacy) { $0.coveredFrom = keepStart ? $0.coveredFrom : from }
        await succeed(org, .anthropicLegacy, coveredThrough: today, empty: fetch.lines.isEmpty)
        return lines.count
    }

    private func syncClaudeCode(_ org: Org, _ client: any ProviderClient, _ today: UTCDay) async throws -> Int {
        let cov = try await store.coverage(orgId: org.id, source: .claudeCode)
        let from = start(covered: cov.coveredThrough, today: today, backfill: config.claudeCodeBackfillDays)
        var n = 0
        var any = false
        for day in UTCDay.range(from: from, through: today) {
            guard let days = try await client.fetchClaudeCode(day: day) else { return 0 }
            try await store.replaceClaudeCodeDay(orgId: org.id, day: day, with: days)
            n += days.count
            any = any || !days.isEmpty
        }
        await succeed(org, .claudeCode, coveredThrough: today, empty: !any)
        return n
    }

    // MARK: OpenAI

    private func syncOpenAI(_ org: Org, _ client: any ProviderClient, _ today: UTCDay, supplemental: Bool) async throws -> Int {
        let source: SyncSource = supplemental ? .openaiCostsByUser : .openaiCosts
        let feed: CostFeed = supplemental ? .openaiCostsByUser : .openaiCosts
        let cov = try await store.coverage(orgId: org.id, source: source)
        let first = cov.coveredThrough == nil
        let from = start(covered: cov.coveredThrough, today: today, backfill: config.openAIBackfillDays)
        var n = 0, any = false, okWindows = 0
        var skippedOld = false
        var firstError: Error?
        for (a, b) in windows(from: from, to: today, size: client.maxCostWindowDays) {
            do {
                let fetch = supplemental ? try await client.fetchSupplementalCosts(from: a, to: b)
                                         : try await client.fetchCosts(from: a, to: b)
                guard let fetch else { return 0 }
                try await store.replaceCostLines(orgId: org.id, feed: feed, from: a, to: b, with: fetch.lines)
                n += fetch.lines.count
                any = any || !fetch.lines.isEmpty
                okWindows += 1
                await update(org, source) { $0.coveredFrom = $0.coveredFrom ?? a; $0.coveredThrough = b }
            } catch ProviderError.badRequest(let m) where first && okWindows == 0 && b < today {
                // History depth is undocumented (RESEARCH.md section 2.2): an old window the API refuses is
                // skipped and the newer windows are tried.
                skippedOld = true
                firstError = ProviderError.badRequest(m)
            }
        }
        if okWindows == 0, let firstError { throw firstError }
        await succeed(org, source, coveredThrough: today, empty: !any,
                      note: skippedOld ? "History before the first accepted window is not available from the API." : nil)
        return n
    }
}
