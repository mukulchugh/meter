import Foundation

// MARK: Readings

public enum ReadingState: String, Sendable, Equatable {
    /// Covered, with spend.
    case value
    /// Covered and confirmed zero. The only case where zero is a real answer.
    case noActivity
    /// Some orgs or days are not covered. `amount` is what is known.
    case partial
    /// Nothing covers the period. `amount` is nil, never zero.
    case missing
}

/// A provider-reported dollar amount for a period, with what is known about its coverage.
public struct Reading: Sendable, Equatable {
    /// US dollars of provider-reported cost. nil when `state == .missing`.
    public var amount: Decimal?
    public var state: ReadingState
    /// Orgs in scope that do not fully cover the period.
    public var missingOrgIds: [String]

    public static let basisLabel = "Provider-reported API cost"

    public init(amount: Decimal?, state: ReadingState, missingOrgIds: [String] = []) {
        self.amount = amount
        self.state = state
        self.missingOrgIds = missingOrgIds
    }
}

public struct OrgTotal: Sendable, Equatable { public var org: Org; public var reading: Reading }
public struct ProviderTotal: Sendable, Equatable { public var provider: Provider; public var reading: Reading }
public struct TagTotal: Sendable, Equatable { public var tag: TagKind; public var reading: Reading }
public struct DailyPoint: Sendable, Equatable { public var day: UTCDay; public var reading: Reading }

extension MeterSnapshot {

    /// Reported spend in `[from, to]`. Never returns zero for data that was not covered.
    public func total(from: UTCDay, to: UTCDay, filter: CostFilter = .all) -> Reading {
        reading(lines: reportedLines(from: from, to: to, filter: filter), from: from, to: to, filter: filter)
    }

    func reading(lines: [CostLine], from: UTCDay, to: UTCDay, filter: CostFilter) -> Reading {
        let orgs = scopedOrgs(filter)
        var full = Set<String>(), notFull = [String]()
        var known = Set<String>()
        for o in orgs {
            let spans = coverageSpans(orgId: o.id)
            if spans.contains(where: { $0.from <= from && $0.through >= to }) {
                known.insert(o.id); full.insert(o.id)
            } else if spans.contains(where: { $0.from <= to && $0.through >= from }) {
                known.insert(o.id); notFull.append(o.id)      // covers only part of the period
            } else {
                notFull.append(o.id)
            }
        }
        guard !known.isEmpty else { return Reading(amount: nil, state: .missing, missingOrgIds: notFull) }
        let used = lines.filter { known.contains($0.orgId) }
        let total = sum(used)
        if !notFull.isEmpty { return Reading(amount: total, state: .partial, missingOrgIds: notFull) }
        return Reading(amount: total, state: used.isEmpty ? .noActivity : .value, missingOrgIds: [])
    }

    public func today(now: Date, filter: CostFilter = .all) -> Reading {
        let d = UTCDay(now)
        return total(from: d, to: d, filter: filter)
    }

    public func monthToDate(now: Date, filter: CostFilter = .all) -> Reading {
        let d = UTCDay(now)
        return total(from: d.monthStart, to: d, filter: filter)
    }

    /// The whole previous calendar month, for "this month vs last month".
    public func previousMonth(now: Date, filter: CostFilter = .all) -> Reading {
        let s = UTCDay(now).previousMonthStart
        return total(from: s, to: s.monthEnd, filter: filter)
    }

    public func totalsByOrg(from: UTCDay, to: UTCDay, filter: CostFilter = .all) -> [OrgTotal] {
        scopedOrgs(filter).map { o in
            var f = filter
            f.orgIds = (filter.orgIds ?? [o.id]).intersection([o.id])
            return OrgTotal(org: o, reading: total(from: from, to: to, filter: f))
        }
    }

    public func totalsByProvider(from: UTCDay, to: UTCDay, filter: CostFilter = .all) -> [ProviderTotal] {
        Provider.allCases.compactMap { p in
            guard filter.provider == nil || filter.provider == p else { return nil }
            var f = filter
            f.provider = p
            return ProviderTotal(provider: p, reading: total(from: from, to: to, filter: f))
        }
    }

    /// App, Team and Untagged, always in that order.
    public func totalsByTag(from: UTCDay, to: UTCDay, filter: CostFilter = .all) -> [TagTotal] {
        TagKind.allCases.map { t in
            var f = filter
            f.tag = t
            return TagTotal(tag: t, reading: total(from: from, to: to, filter: f))
        }
    }

    /// The last `days` days ending on the day of `now` (inclusive), oldest first.
    public func dailySeries(days: Int, now: Date, filter: CostFilter = .all) -> [DailyPoint] {
        let end = UTCDay(now)
        let start = end.adding(-(max(days, 1) - 1))
        let byDay = Dictionary(grouping: reportedLines(from: start, to: end, filter: filter), by: \.day)
        return UTCDay.range(from: start, through: end).map {
            DailyPoint(day: $0, reading: reading(lines: byDay[$0] ?? [], from: $0, to: $0, filter: filter))
        }
    }

    public func weekSeries(now: Date, filter: CostFilter = .all) -> [DailyPoint] { dailySeries(days: 7, now: now, filter: filter) }
    public func monthSeries(now: Date, filter: CostFilter = .all) -> [DailyPoint] { dailySeries(days: 30, now: now, filter: filter) }

    /// Provider-estimated spend, shown on its own. Never part of any reported total.
    public func estimatedTotal(from: UTCDay, to: UTCDay, filter: CostFilter = .all) -> Decimal {
        lines.filter { $0.source == .estimated && $0.currency == "USD" && $0.day >= from && $0.day <= to && matches($0, filter) }
            .reduce(0) { $0 + $1.amount }
    }
}

// MARK: Top drivers

public enum DriverDimension: String, Sendable, CaseIterable { case model, apiKey, project, person }

public struct Driver: Sendable, Equatable {
    public var id: String?
    public var name: String
    public var orgId: String?
    public var provider: Provider?
    public var amount: Decimal
    /// Share of the reported total in the same scope, nil when that total is zero.
    public var share: Double?
    /// The provider gave no value for this dimension (for example legacy lines have no API key).
    public var isUnattributed: Bool
}

extension MeterSnapshot {
    public func topDrivers(_ dimension: DriverDimension, limit: Int = 5, from: UTCDay, to: UTCDay,
                           filter: CostFilter = .all) -> [Driver] {
        let lines = reportedLines(from: from, to: to, filter: filter)
        let total = sum(lines)
        func share(_ a: Decimal) -> Double? { total > 0 ? NSDecimalNumber(decimal: a / total).doubleValue : nil }
        var drivers = [Driver]()

        switch dimension {
        case .model:
            for (model, ls) in Dictionary(grouping: lines, by: { $0.model }) {
                let a = sum(ls)
                drivers.append(Driver(id: model, name: model ?? "Unknown model", orgId: nil, provider: nil, amount: a,
                                      share: share(a), isUnattributed: model == nil))
            }
        case .apiKey, .project:
            struct K: Hashable { let org: String; let id: String? }
            let isKey = dimension == .apiKey
            for (k, ls) in Dictionary(grouping: lines, by: { K(org: $0.orgId, id: isKey ? $0.apiKeyId : $0.projectId) }) {
                let a = sum(ls)
                let provider = orgsById[k.org]?.provider
                let name: String
                var unattributed = false
                if let id = k.id {
                    name = entity(orgId: k.org, kind: isKey ? .apiKey : .project, id: id)?.name ?? id
                } else if isKey {
                    name = "No API key (provider gave none)"; unattributed = true
                } else if provider == .anthropic {
                    name = "Default workspace"
                } else {
                    name = "No project"; unattributed = true
                }
                drivers.append(Driver(id: k.id, name: name, orgId: k.org, provider: provider, amount: a,
                                      share: share(a), isUnattributed: unattributed))
            }
        case .person:
            let r = people(from: from, to: to, filter: filter)
            for p in r.people {
                drivers.append(Driver(id: p.email, name: p.displayName, orgId: nil, provider: nil, amount: p.total,
                                      share: share(p.total), isUnattributed: false))
            }
            let rest = r.unmatched.reduce(Decimal(0)) { $0 + $1.amount }
            if rest > 0 {
                drivers.append(Driver(id: nil, name: "Unmatched people", orgId: nil, provider: nil, amount: rest,
                                      share: share(rest), isUnattributed: true))
            }
        }
        drivers.sort { $0.amount != $1.amount ? $0.amount > $1.amount : $0.name < $1.name }
        return Array(drivers.prefix(limit))
    }
}

// MARK: People

public struct PersonSpend: Sendable, Equatable {
    /// Lower-cased. The merge key across providers.
    public var email: String
    public var displayName: String
    public var byOrg: [String: Decimal]
    public var byProvider: [Provider: Decimal]
    public var total: Decimal
}

public struct UnmatchedActor: Sendable, Equatable {
    public enum Reason: String, Sendable { case noUserRecord, noEmail, nonUserActor }
    public var orgId: String
    public var provider: Provider?
    public var actorId: String
    public var name: String?
    public var amount: Decimal
    public var reason: Reason
}

public struct PeopleResult: Sendable, Equatable {
    public var people: [PersonSpend]
    /// Actors that could not be tied to an email. Listed explicitly, never silently dropped or merged.
    public var unmatched: [UnmatchedActor]
}

extension MeterSnapshot {
    /// Spend per person, merged across providers and orgs by case-insensitive email. Uses Anthropic's
    /// `actor` dimension and OpenAI's by-user pass. Days that only have a coarse feed (Anthropic legacy)
    /// carry no actor, so a person's total can sit below the org total. That gap is not an error.
    public func people(from: UTCDay, to: UTCDay, filter: CostFilter = .all) -> PeopleResult {
        let personLines = lines.filter {
            $0.source == .reported && $0.currency == "USD" && $0.actor != nil && $0.day >= from && $0.day <= to
                && matches($0, filter)
        }
        var byEmail = [String: PersonSpend]()
        struct U: Hashable { let org: String; let actor: String }
        var unmatched = [U: UnmatchedActor]()

        for l in personLines {
            guard let actor = l.actor else { continue }
            var email: String?
            var name: String?
            var reason: UnmatchedActor.Reason?
            if let u = entity(orgId: l.orgId, kind: .user, id: actor) {
                name = u.name
                if let e = u.email?.lowercased(), !e.isEmpty { email = e } else { reason = .noEmail }
            } else if entity(orgId: l.orgId, kind: .apiKey, id: actor) != nil {
                reason = .nonUserActor
            } else if actor.contains("@") {
                email = actor.lowercased()
            } else {
                reason = .noUserRecord
            }
            if let email {
                var p = byEmail[email] ?? PersonSpend(email: email, displayName: name ?? email, byOrg: [:], byProvider: [:], total: 0)
                if let name, p.displayName == p.email { p.displayName = name }
                p.byOrg[l.orgId, default: 0] += l.amount
                if let prov = orgsById[l.orgId]?.provider { p.byProvider[prov, default: 0] += l.amount }
                p.total += l.amount
                byEmail[email] = p
            } else if let reason {
                let k = U(org: l.orgId, actor: actor)
                var u = unmatched[k] ?? UnmatchedActor(orgId: l.orgId, provider: orgsById[l.orgId]?.provider, actorId: actor,
                                                       name: name, amount: 0, reason: reason)
                u.amount += l.amount
                unmatched[k] = u
            }
        }
        return PeopleResult(
            people: byEmail.values.sorted { $0.total != $1.total ? $0.total > $1.total : $0.email < $1.email },
            unmatched: unmatched.values.sorted { $0.amount != $1.amount ? $0.amount > $1.amount : $0.actorId < $1.actorId })
    }
}

// MARK: Tracking (projection, budgets, limits, prepaid)

public struct Projection: Sendable, Equatable {
    /// Month to date, including today's partial figure.
    public var monthToDate: Reading
    /// Mean of the covered days in the 7 days before today. nil when fewer than 3 days are covered.
    public var runRateDaily: Decimal?
    public var runRateDays: Int
    /// Spend through yesterday plus the run rate for every remaining day, today included.
    public var projectedByRunRate: Decimal?
    /// Share of the month elapsed at `now`, 0 to 1.
    public var elapsedFraction: Double
    /// Month to date divided by the elapsed fraction. Shown beside the run rate, not instead of it.
    public var projectedByElapsedFraction: Decimal?
    public var monthEnd: UTCDay
}

public struct Tracking: Sendable, Equatable {
    public var reading: Reading
    public var target: Decimal
    public var used: Decimal?
    public var percent: Double?
    public var exceeded: Bool
    public var projection: Projection
    /// For each percent threshold not yet crossed, the projected UTC day it will be, if within this month.
    public var projectedCrossings: [Int: UTCDay]
}

extension MeterSnapshot {
    static let minRateDays = 3

    public func projection(now: Date, filter: CostFilter = .all) -> Projection {
        let today = UTCDay(now)
        let mtd = monthToDate(now: now, filter: filter)

        let start = today.adding(-7), end = today.adding(-1)
        let byDay = Dictionary(grouping: reportedLines(from: start, to: end, filter: filter), by: \.day)
        var covered = [Decimal]()
        for d in UTCDay.range(from: start, through: end) {
            let r = reading(lines: byDay[d] ?? [], from: d, to: d, filter: filter)
            if r.state == .value || r.state == .noActivity, let a = r.amount { covered.append(a) }
        }
        let rate: Decimal? = covered.count >= Self.minRateDays ? covered.reduce(0, +) / Decimal(covered.count) : nil

        let yesterday = today.adding(-1)
        let throughYesterday = yesterday >= today.monthStart
            ? sum(reportedLines(from: today.monthStart, to: yesterday, filter: filter)) : 0
        let remainingDays = today.daysInMonth - (today.day - 1)
        let byRate = rate.map { throughYesterday + $0 * Decimal(remainingDays) }

        let monthStart = today.monthStart.start
        let span = today.nextMonthStart.start.timeIntervalSince(monthStart)
        let fraction = min(max(now.timeIntervalSince(monthStart) / span, 0), 1)
        let byFraction: Decimal? = (mtd.amount != nil && fraction > 0) ? mtd.amount.map { $0 / Decimal(fraction) } : nil

        return Projection(monthToDate: mtd, runRateDaily: rate, runRateDays: covered.count, projectedByRunRate: byRate,
                          elapsedFraction: fraction, projectedByElapsedFraction: byFraction, monthEnd: today.monthEnd)
    }

    func tracking(filter: CostFilter, target: Decimal, thresholds: [Int], now: Date) -> Tracking {
        let proj = projection(now: now, filter: filter)
        let used = proj.monthToDate.amount
        let percent: Double? = (used != nil && target > 0) ? used.map { NSDecimalNumber(decimal: $0 / target * 100).doubleValue } : nil
        let exceeded = used.map { $0 >= target } ?? false

        var crossings = [Int: UTCDay]()
        let today = UTCDay(now)
        if let rate = proj.runRateDaily, rate > 0, let used {
            let yesterday = today.adding(-1)
            let throughYesterday = yesterday >= today.monthStart
                ? sum(reportedLines(from: today.monthStart, to: yesterday, filter: filter)) : 0
            for t in thresholds {
                let level = target * Decimal(t) / 100
                if used >= level { continue }
                var q = (level - throughYesterday) / rate
                var rounded = Decimal()
                NSDecimalRound(&rounded, &q, 0, .up)
                let n = max(NSDecimalNumber(decimal: rounded).intValue, 1)
                let day = today.adding(n - 1)
                if day <= today.monthEnd { crossings[t] = day }
            }
        }
        return Tracking(reading: proj.monthToDate, target: target, used: used, percent: percent, exceeded: exceeded,
                        projection: proj, projectedCrossings: crossings)
    }
}

public struct BudgetStatus: Sendable, Equatable {
    public var budget: Budget
    public var tracking: Tracking
    /// Thresholds already reached, ascending.
    public var thresholdsCrossed: [Int]
    public var nextThreshold: Int?
    /// Projected UTC day the budget reaches 100%, if it does within this month.
    public var projectedCrossing: UTCDay? { tracking.projectedCrossings[100] }
    /// Budgets are alerts. They never stop spend.
    public var consequence: String { "Alert target: does not stop requests" }
}

extension MeterSnapshot {
    public func filter(for scope: BudgetScope) -> CostFilter {
        switch scope {
        case .overall: .all
        case .org(let id): CostFilter(orgIds: [id])
        case .tag(let t): CostFilter(tag: t)
        case .project(let o, let p): CostFilter(project: ProjectRef(orgId: o, projectId: p))
        }
    }

    public func budgetStatus(_ b: Budget, now: Date) -> BudgetStatus {
        let t = tracking(filter: filter(for: b.scope), target: b.amount, thresholds: b.thresholds, now: now)
        let crossed = t.used.map { used in b.thresholds.filter { used * 100 >= b.amount * Decimal($0) } } ?? []
        return BudgetStatus(budget: b, tracking: t, thresholdsCrossed: crossed,
                            nextThreshold: b.thresholds.first { !crossed.contains($0) })
    }

    public func budgetStatuses(now: Date) -> [BudgetStatus] { budgets.map { budgetStatus($0, now: now) } }
}

public struct LimitStatus: Sendable, Equatable {
    public var limit: Limit
    public var tracking: Tracking
    public var projectedCrossing: UTCDay? { tracking.projectedCrossings[100] }
    public var consequence: String {
        limit.kind == .hardLimit ? "Provider-enforced limit" : "Alert only: does not stop requests"
    }
}

extension MeterSnapshot {
    /// Month-to-date reported spend (org or project) against an OpenAI limit or alert, with the projected
    /// date to reach it. Read-only: Meter never writes limits.
    public func limitStatus(_ l: Limit, now: Date) -> LimitStatus {
        let f = l.projectId.map { CostFilter(project: ProjectRef(orgId: l.orgId, projectId: $0)) } ?? CostFilter(orgIds: [l.orgId])
        return LimitStatus(limit: l, tracking: tracking(filter: f, target: l.thresholdUSD, thresholds: [100], now: now))
    }

    public func limitStatuses(now: Date) -> [LimitStatus] { limits.map { limitStatus($0, now: now) } }
}

public struct PrepaidStatus: Sendable, Equatable {
    public var orgId: String
    public var enteredAmount: Decimal
    public var enteredAt: Date
    public var spentSinceEntry: Decimal
    /// Entered amount minus reported spend since entry. Can go negative.
    public var remaining: Decimal
    public var dailyRate: Decimal?
    public var daysLeft: Double?
    public var projectedRunOut: UTCDay?
    public var isDepleted: Bool
    /// Spend since entry is partial (an org not covered through today).
    public var spendIsPartial: Bool
    public let label = "Estimate from a manually entered balance"
}

extension MeterSnapshot {
    /// Remaining = latest entered balance minus reported spend since that day (the entry day included,
    /// which errs toward showing less). Days left uses the 7-day run rate.
    public func prepaidStatus(orgId: String, now: Date) -> PrepaidStatus? {
        guard let p = prepaid.filter({ $0.orgId == orgId }).max(by: { $0.enteredAt < $1.enteredAt }) else { return nil }
        let today = UTCDay(now)
        let from = UTCDay(p.enteredAt)
        let f = CostFilter(orgIds: [orgId])
        let spent = total(from: from, to: max(from, today), filter: f)
        let remaining = p.amount - (spent.amount ?? 0)
        let rate = projection(now: now, filter: f).runRateDaily
        var daysLeft: Double?
        var runOut: UTCDay?
        if let rate, rate > 0, remaining > 0 {
            let d = NSDecimalNumber(decimal: remaining / rate).doubleValue
            daysLeft = d
            runOut = today.adding(Int(d.rounded(.down)))
        }
        return PrepaidStatus(orgId: orgId, enteredAmount: p.amount, enteredAt: p.enteredAt,
                             spentSinceEntry: spent.amount ?? 0, remaining: remaining, dailyRate: rate, daysLeft: daysLeft,
                             projectedRunOut: runOut, isDepleted: remaining <= 0,
                             spendIsPartial: spent.state == .partial || spent.state == .missing)
    }
}

// MARK: Spikes

public struct Spike: Sendable, Equatable {
    public var day: UTCDay
    public var amount: Decimal
    public var baselineAverage: Decimal
    public var ratio: Double
}

extension MeterSnapshot {
    static let spikeFactor: Decimal = 2
    static let spikeBaselineDays = 14
    static let spikeMinBaselineDays = 7

    /// Days in the last `lookbackDays` whose spend is more than 2x the average of the 14 covered days
    /// before them. A baseline needs at least 7 covered days and a nonzero mean.
    public func spikes(now: Date, lookbackDays: Int = 7, filter: CostFilter = .all) -> [Spike] {
        let today = UTCDay(now)
        let first = today.adding(-(lookbackDays - 1))
        let start = first.adding(-Self.spikeBaselineDays)
        let byDay = Dictionary(grouping: reportedLines(from: start, to: today, filter: filter), by: \.day)
        var amounts = [UTCDay: Decimal]()
        for d in UTCDay.range(from: start, through: today) {
            let r = reading(lines: byDay[d] ?? [], from: d, to: d, filter: filter)
            if r.state == .value || r.state == .noActivity, let a = r.amount { amounts[d] = a }
        }
        var out = [Spike]()
        for d in UTCDay.range(from: first, through: today) {
            guard let a = amounts[d] else { continue }
            let base = (1...Self.spikeBaselineDays).compactMap { amounts[d.adding(-$0)] }
            guard base.count >= Self.spikeMinBaselineDays else { continue }
            let avg = base.reduce(0, +) / Decimal(base.count)
            guard avg > 0, a > avg * Self.spikeFactor else { continue }
            out.append(Spike(day: d, amount: a, baselineAverage: avg, ratio: NSDecimalNumber(decimal: a / avg).doubleValue))
        }
        return out
    }
}

// MARK: Claude Code

public struct ClaudeCodePerson: Sendable, Equatable {
    /// Lower-cased email for users, key name for API actors.
    public var id: String
    public var actorType: ClaudeCodeDay.ActorType
    public var sessions: Int
    public var linesAdded: Int
    public var linesRemoved: Int
    public var commits: Int
    public var pullRequests: Int
    /// Provider-estimated Claude Code cost. Shown on its own; never added to org spend.
    public var estimatedCost: Decimal
    /// The same person's provider-reported spend (all products) in the period, from `people`. nil when
    /// that person has no attributed reported spend.
    public var reportedSpend: Decimal?
}

extension MeterSnapshot {
    public func claudeCodeActivity(from: UTCDay, to: UTCDay, filter: CostFilter = .all) -> [ClaudeCodePerson] {
        struct K: Hashable { let type: ClaudeCodeDay.ActorType; let id: String; let org: String? }
        let reported = Dictionary(uniqueKeysWithValues: people(from: from, to: to, filter: filter).people.map { ($0.email, $0.total) })
        var rows = [K: ClaudeCodePerson]()
        for d in claudeCode where d.day >= from && d.day <= to {
            if let ids = filter.orgIds, !ids.contains(d.orgId) { continue }
            if let p = filter.provider, orgsById[d.orgId]?.provider != p { continue }
            let id = d.actorType == .user ? d.actorKey.lowercased() : d.actorKey
            // People merge across orgs; API actors stay per org because key names are only unique within one.
            let k = K(type: d.actorType, id: id, org: d.actorType == .user ? nil : d.orgId)
            var r = rows[k] ?? ClaudeCodePerson(id: id, actorType: d.actorType, sessions: 0, linesAdded: 0, linesRemoved: 0,
                                                commits: 0, pullRequests: 0, estimatedCost: 0,
                                                reportedSpend: d.actorType == .user ? reported[id] : nil)
            r.sessions += d.sessions
            r.linesAdded += d.linesAdded
            r.linesRemoved += d.linesRemoved
            r.commits += d.commits
            r.pullRequests += d.pullRequests
            r.estimatedCost += d.estimatedCost
            rows[k] = r
        }
        return rows.values.sorted { $0.estimatedCost != $1.estimatedCost ? $0.estimatedCost > $1.estimatedCost : $0.id < $1.id }
    }
}

// MARK: Coverage summary

public struct SourceStatus: Sendable, Equatable {
    public var source: SyncSource
    public var state: FreshnessState
    public var lastSuccess: Date?
    public var watermark: Date?
    public var lastError: String?
    public var hasLastKnownValue: Bool
    public var note: String?
}

public struct OrgCoverage: Sendable, Equatable {
    public var org: Org
    /// The worst state across the org's sources. `connected` when nothing has synced yet.
    public var state: FreshnessState
    public var sources: [SourceStatus]
    /// Latest day dollars are stored through, nil if never.
    public var coveredThrough: UTCDay?
    /// A dollar feed is in error or stale. Slower, normal lag (`delayed`) and a missing per-user breakdown
    /// do not count: the number is still trustworthy.
    public var needsAttention: Bool
}

public struct CoverageSummary: Sendable, Equatable {
    public var orgs: [OrgCoverage]
    /// True when a dollar feed is in error or stale, so the menu bar should show an attention mark.
    /// An org that has never synced is not flagged here: its totals read `.missing`.
    public var needsAttention: Bool
    /// The oldest provider watermark across orgs ("data through"), nil if no provider gave one.
    public var dataThrough: Date?
    /// The oldest last-successful fetch across orgs.
    public var oldestSuccess: Date?
}

extension MeterSnapshot {
    public func coverageSummary(now: Date, policy: FreshnessPolicy = .default) -> CoverageSummary {
        var out = [OrgCoverage]()
        for o in orgs.sorted(by: { $0.displayName < $1.displayName }) {
            let sources = coverage.filter { $0.orgId == o.id }.sorted { $0.source.rawValue < $1.source.rawValue }.map {
                SourceStatus(source: $0.source, state: $0.state(now: now, policy: policy), lastSuccess: $0.lastSuccess,
                             watermark: $0.watermark, lastError: $0.lastError, hasLastKnownValue: $0.hasLastKnownValue, note: $0.note)
            }
            let worst = sources.map(\.state).max { $0.severity < $1.severity } ?? .connected
            let attention = sources.contains { $0.source.isPrimaryCost && ($0.state == .error || $0.state == .stale) }
            out.append(OrgCoverage(org: o, state: worst, sources: sources, coveredThrough: coveredThrough(orgId: o.id),
                                   needsAttention: attention))
        }
        let marks = coverage.compactMap(\.watermark)
        let successes = coverage.filter { $0.source.isPrimaryCost }.compactMap(\.lastSuccess)
        return CoverageSummary(orgs: out, needsAttention: out.contains { $0.needsAttention },
                               dataThrough: marks.min(), oldestSuccess: successes.min())
    }
}

// MARK: Tag suggestions

public struct TagSuggestion: Sendable, Equatable {
    public var orgId: String
    public var target: TagTarget
    public var targetId: String
    public var name: String
    public var suggested: TagKind
    public var reason: String
}

/// Proposes a tag from a name. It only proposes: nothing here writes a tag (PLAN.md, "Product vs team").
public enum TagSuggester {
    static let appWords: Set<String> = ["prod", "production", "app", "api"]
    static let teamWords: Set<String> = ["dev", "development", "local"]

    static func tokens(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// `personNames` are the full names and emails of known users in the org.
    public static func suggest(name: String, personNames: [String]) -> (tag: TagKind, reason: String)? {
        let toks = Set(tokens(name))
        let appHit = toks.intersection(appWords).sorted()
        var teamHit = toks.intersection(teamWords).sorted()
        var personHit = [String]()
        var person = Set<String>()
        for n in personNames {
            let source = n.contains("@") ? String(n.split(separator: "@")[0]) : n
            for t in tokens(source) where t.count >= 3 && !appWords.contains(t) && !teamWords.contains(t) { person.insert(t) }
        }
        personHit = toks.intersection(person).sorted()
        teamHit += personHit
        switch (appHit.isEmpty, teamHit.isEmpty) {
        case (false, true): return (.app, "Name contains \"\(appHit[0])\"")
        case (true, false):
            return (.team, personHit.isEmpty ? "Name contains \"\(teamHit[0])\"" : "Name looks like a person (\"\(personHit[0])\")")
        default: return nil
        }
    }
}

extension MeterSnapshot {
    /// Suggestions for keys and projects that are still untagged. Apply only on the CTO's say-so.
    public func tagSuggestions() -> [TagSuggestion] {
        var out = [TagSuggestion]()
        for e in entities where (e.kind == .apiKey || e.kind == .project) && !e.archived {
            let target: TagTarget = e.kind == .apiKey ? .apiKey : .project
            if tagIndex[TagKey(orgId: e.orgId, target: target, id: e.id)] != nil { continue }
            let people = entities.filter { $0.orgId == e.orgId && $0.kind == .user }.flatMap { [$0.name, $0.email ?? ""] }
            if let s = TagSuggester.suggest(name: e.name, personNames: people) {
                out.append(TagSuggestion(orgId: e.orgId, target: target, targetId: e.id, name: e.name, suggested: s.tag, reason: s.reason))
            }
        }
        return out.sorted { ($0.orgId, $0.name) < ($1.orgId, $1.name) }
    }
}
