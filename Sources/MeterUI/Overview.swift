import Foundation
import MeterCore

public struct Comparison: Equatable, Sendable {
    public var thisMonth: Reading
    public var lastMonth: Reading
    /// nil unless both months are fully covered.
    public var changePercent: Double?
    public var changeText: String {
        guard let c = changePercent else { return "No comparison yet" }
        return (c >= 0 ? "+" : "") + Fmt.percent(c) + " vs last month"
    }
}

public struct ProjectionView: Equatable, Sendable {
    public var projection: Projection
    public var budget: Budget?
    public var runRateText: String
    public var elapsedText: String
    public var budgetNote: String?
}

public struct DriverRow: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var orgName: String?
    public var amountText: String
    public var shareText: String
    public var share: Double
    public var isUnattributed: Bool
}

public struct SpikeRow: Equatable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var detail: String
}

public struct CoverageChip: Equatable, Identifiable, Sendable {
    public var id: String
    public var orgName: String
    public var state: FreshnessState
    public var detail: String
}

public struct OverviewContent: Equatable, Sendable {
    public var comparison: Comparison
    public var projection: ProjectionView
    public var split: [SplitRow]
    public var drivers: [DriverRow]
    public var spikes: [SpikeRow]
    public var daily: [ChartPoint]
    public var cumulative: [ChartPoint]
    public var cumulativeHasGaps: Bool
    public var chips: [CoverageChip]
    public var monthTitle: String

    public init(snapshot: MeterSnapshot, now: Date, scope: Scope, driverDimension: DriverDimension = .project) {
        let filter = scope.filter
        let day = UTCDay(now)
        monthTitle = Fmt.monthName(day)

        let this = snapshot.monthToDate(now: now, filter: filter)
        let last = snapshot.previousMonth(now: now, filter: filter)
        var change: Double?
        if let a = this.amount, let b = last.amount, b > 0, this.state != .partial, last.state != .partial {
            change = Fmt.chartValue((a - b) / b * 100)
        }
        comparison = Comparison(thisMonth: this, lastMonth: last, changePercent: change)

        let proj = snapshot.projection(now: now, filter: filter)
        let overall = snapshot.budgets.first { $0.scope == .overall }
        projection = ProjectionView(
            projection: proj, budget: overall,
            runRateText: proj.projectedByRunRate.map { "\(Fmt.usd($0)) at the run rate" }
                ?? "Run rate needs 3 covered days",
            elapsedText: proj.projectedByElapsedFraction.map { "\(Fmt.usd($0)) at \(Fmt.percent(proj.elapsedFraction * 100)) of the month elapsed" }
                ?? "No projection yet",
            budgetNote: overall.map { "Budget \(Fmt.usd($0.amount)), alert only, does not stop spend" })

        split = snapshot.totalsByTag(from: day.monthStart, to: day, filter: filter).map { SplitRow(tag: $0.tag, reading: $0.reading) }

        drivers = snapshot.topDrivers(driverDimension, limit: 5, from: day.monthStart, to: day, filter: filter).enumerated().map { i, d in
            DriverRow(id: "\(i)-\(d.id ?? d.name)", name: d.name, orgName: d.orgId.flatMap { snapshot.org($0)?.displayName },
                      amountText: Fmt.usd(d.amount), shareText: Fmt.share(d.share), share: d.share ?? 0, isUnattributed: d.isUnattributed)
        }

        spikes = snapshot.spikes(now: now, lookbackDays: 7, filter: filter).map {
            SpikeRow(id: $0.day.string, text: "\(Fmt.shortDay($0.day)): \(Fmt.usd($0.amount))",
                     detail: "\(String(format: "%.1f", $0.ratio))x the 14-day average of \(Fmt.usd($0.baselineAverage))")
        }

        let series = snapshot.dailySeries(days: day.day, now: now, filter: filter)
        daily = series.map { ChartPoint(day: $0.day, label: String($0.day.day), value: $0.reading.amount.map(Fmt.chartValue)) }
        var running: Decimal = 0
        var gaps = false
        var points = [ChartPoint]()
        for p in series {
            if let a = p.reading.amount { running += a } else { gaps = true }
            points.append(ChartPoint(day: p.day, label: String(p.day.day), value: Fmt.chartValue(running)))
        }
        cumulative = points
        cumulativeHasGaps = gaps || this.state == .partial

        chips = ScopedCoverage(snapshot: snapshot, now: now, scope: scope).orgs.map {
            CoverageChip(id: $0.org.id, orgName: $0.org.displayName, state: $0.state,
                         detail: Freshness.text(for: $0, snapshot: snapshot, now: now))
        }
    }
}
