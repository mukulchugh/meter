import Foundation
import MeterCore

public enum MenuMetric: String, CaseIterable, Sendable, Identifiable {
    case today, mtd, iconOnly
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .today: "Today"
        case .mtd: "Month to date"
        case .iconOnly: "Icon only"
        }
    }
    var suffix: String { self == .mtd ? "MTD" : "today" }
}

/// All organizations, or one.
public enum Scope: Hashable, Sendable {
    case all
    case org(String)

    public var filter: CostFilter {
        switch self {
        case .all: .all
        case .org(let id): CostFilter(orgIds: [id])
        }
    }
    public var raw: String {
        switch self {
        case .all: "all"
        case .org(let id): "org:\(id)"
        }
    }
    public init(raw: String) {
        if raw.hasPrefix("org:") { self = .org(String(raw.dropFirst(4))) } else { self = .all }
    }
    public func label(in snapshot: MeterSnapshot) -> String {
        switch self {
        case .all: snapshot.orgs.isEmpty ? "No organizations" : "All organizations"
        case .org(let id): snapshot.org(id)?.displayName ?? "All organizations"
        }
    }
}

/// Coverage restricted to the orgs in scope.
public struct ScopedCoverage: Sendable, Equatable {
    public var orgs: [OrgCoverage]
    public var needsAttention: Bool
    /// The oldest provider report time among the orgs in scope.
    public var oldestReport: Date?

    public init(snapshot: MeterSnapshot, now: Date, scope: Scope) {
        let all = snapshot.coverageSummary(now: now).orgs
        switch scope {
        case .all: orgs = all
        case .org(let id): orgs = all.filter { $0.org.id == id }
        }
        needsAttention = orgs.contains { $0.needsAttention }
        oldestReport = orgs.compactMap(Freshness.reportTime).min()
    }
}

/// What the menu bar shows. A missing reading shows the attention glyph and the last known value, never $0.
public struct MenuBarTitle: Sendable, Equatable {
    public var text: String?
    public var showsAttention: Bool
    public var accessibilityLabel: String

    public static func make(metric: MenuMetric, snapshot: MeterSnapshot, now: Date, scope: Scope,
                            lastKnown: Decimal?) -> MenuBarTitle {
        let filter = scope.filter
        let reading = metric == .mtd ? snapshot.monthToDate(now: now, filter: filter) : snapshot.today(now: now, filter: filter)
        let coverage = ScopedCoverage(snapshot: snapshot, now: now, scope: scope)
        let attention = reading.state == .missing || reading.state == .partial || coverage.needsAttention
        let amount = reading.amount ?? lastKnown
        let basis = metric == .mtd ? "month to date" : "today"
        if metric == .iconOnly {
            return MenuBarTitle(text: nil, showsAttention: attention,
                                accessibilityLabel: attention ? "Meter, needs attention" : "Meter")
        }
        guard let amount else {
            return MenuBarTitle(text: nil, showsAttention: true, accessibilityLabel: "Meter, no spend data yet")
        }
        let text = "\(Fmt.usdCompact(amount)) \(metric.suffix)"
        var label = "Meter, \(Fmt.usd(amount)) \(basis), provider-reported"
        if reading.amount == nil { label += ", last known value, data is missing" }
        else if attention { label += ", needs attention" }
        return MenuBarTitle(text: text, showsAttention: attention, accessibilityLabel: label)
    }
}

public struct ChartPoint: Equatable, Identifiable, Sendable {
    public var day: UTCDay
    public var label: String
    /// Chart geometry only. nil when the day has no data, which is left empty rather than drawn as zero.
    public var value: Double?
    public var id: String { day.string }
}

public struct SplitRow: Equatable, Identifiable, Sendable {
    public var tag: TagKind
    public var reading: Reading
    public var id: String { tag.rawValue }
    public var title: String { tag.title }
    public var text: String { Fmt.reading(reading) }
}

extension TagKind {
    public var title: String {
        switch self {
        case .app: "App"
        case .team: "Team"
        case .untagged: "Untagged"
        }
    }
}

public struct OrgRow: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var provider: Provider
    public var reading: Reading
    public var freshness: String
    public var state: FreshnessState
    public var amountText: String { Fmt.reading(reading) }
}

public struct BudgetBar: Equatable, Sendable {
    public var name: String
    public var usedText: String
    public var targetText: String
    public var percentText: String
    /// 0 to 1, for the bar.
    public var fraction: Double
    public var exceeded: Bool
    public static let note = "alert only, does not stop spend"
}

public struct PopoverContent: Equatable, Sendable {
    public var scopeLabel: String
    public var reportedText: String
    public var today: Reading
    public var split: [SplitRow]
    public var orgs: [OrgRow]
    public var week: [ChartPoint]
    public var budget: BudgetBar?
    public var title: MenuBarTitle
    /// False before the first organization exists: the popover shows its empty state instead.
    public var hasOrgs: Bool

    public var todayText: String { Fmt.reading(today) }

    public init(snapshot: MeterSnapshot, now: Date, scope: Scope, metric: MenuMetric = .today, lastKnown: Decimal? = nil) {
        let filter = scope.filter
        let day = UTCDay(now)
        scopeLabel = scope.label(in: snapshot)
        hasOrgs = !snapshot.orgs.isEmpty
        today = snapshot.today(now: now, filter: filter)
        split = snapshot.totalsByTag(from: day, to: day, filter: filter).map { SplitRow(tag: $0.tag, reading: $0.reading) }

        let coverage = ScopedCoverage(snapshot: snapshot, now: now, scope: scope)
        if let t = coverage.oldestReport {
            reportedText = "Reported through \(Fmt.utcTime(t)), \(Fmt.ago(t, now: now))"
        } else {
            reportedText = snapshot.orgs.isEmpty ? "Add an organization to start" : "No report yet"
        }

        let totals = Dictionary(uniqueKeysWithValues: snapshot.totalsByOrg(from: day, to: day, filter: filter).map { ($0.org.id, $0.reading) })
        let rows = coverage.orgs.map { c in
            OrgRow(id: c.org.id, name: c.org.displayName, provider: c.org.provider,
                   reading: totals[c.org.id] ?? Reading(amount: nil, state: .missing, missingOrgIds: [c.org.id]),
                   freshness: Freshness.text(for: c, snapshot: snapshot, now: now), state: c.state)
        }
        // Largest spend first; orgs with no reading go last, then by name.
        orgs = rows.sorted {
            switch ($0.reading.amount, $1.reading.amount) {
            case let (a?, b?) where a != b: return a > b
            case (nil, _?): return false
            case (_?, nil): return true
            default: return $0.name < $1.name
            }
        }

        week = snapshot.weekSeries(now: now, filter: filter).map {
            ChartPoint(day: $0.day, label: Fmt.weekday($0.day), value: $0.reading.amount.map(Fmt.chartValue))
        }

        budget = snapshot.budgetStatuses(now: now).first { $0.budget.scope == .overall }.map(BudgetBar.init)
        title = MenuBarTitle.make(metric: metric, snapshot: snapshot, now: now, scope: scope, lastKnown: lastKnown)
    }
}

extension BudgetBar {
    init(_ s: BudgetStatus) {
        name = s.budget.name
        usedText = Fmt.usd(s.tracking.used)
        targetText = Fmt.usd(s.budget.amount)
        percentText = s.tracking.percent.map(Fmt.percent) ?? Fmt.noData
        fraction = min(max((s.tracking.percent ?? 0) / 100, 0), 1)
        exceeded = s.tracking.exceeded
    }
}
