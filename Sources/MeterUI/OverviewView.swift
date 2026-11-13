import MeterCore
import SwiftUI

struct OverviewView: View {
    let model: AppModel
    @State private var dimension: DriverDimension = .project

    var body: some View {
        if model.snapshot.orgs.isEmpty {
            NoOrgsView(add: { model.beginAddOrganization() }, preview: { Task { await model.enterPreview() } })
        } else {
            let c = OverviewContent(snapshot: model.snapshot, now: model.now, scope: model.scope, driverDimension: dimension)
            Screen {
                FlowRow { ForEach(c.chips) { CoverageChipView(chip: $0) } }
                HStack(alignment: .top, spacing: 14) {
                    Card("\(c.monthTitle) so far") {
                        HStack { BasisTag(basis: .reported); Text(Reading.basisLabel).font(.caption).foregroundStyle(.secondary) }
                        ReadingText(reading: c.comparison.thisMonth)
                        Text(c.comparison.changeText).font(.callout).foregroundStyle(.secondary)
                        Text("Last month: \(Fmt.reading(c.comparison.lastMonth))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Card("Projected month end") {
                        projection(c.projection)
                    }
                    Card("App vs Team") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(c.split) { r in
                                HStack { Text(r.title); Spacer(); Text(r.text).monospacedDigit() }.font(.callout)
                            }
                        }
                        if c.split.first(where: { $0.tag == .untagged }).map({ ($0.reading.amount ?? 0) > 0 }) == true {
                            Button("Tag keys and projects") { model.selection = .keys }.buttonStyle(.link).font(.caption)
                        }
                    }
                }
                Card("Daily spend") {
                    DailyBars(points: c.daily, height: 150, labelEvery: 5)
                    Text("Days without data are left empty, not drawn as zero.").font(.caption).foregroundStyle(.secondary)
                }
                Card("Cumulative this month") {
                    CumulativeLine(points: c.cumulative)
                    if c.cumulativeHasGaps {
                        Label("Includes days with no data, so the line may sit low.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    Card("Top 5 drivers") {
                        Picker("By", selection: $dimension) {
                            Text("Project").tag(DriverDimension.project)
                            Text("Key").tag(DriverDimension.apiKey)
                            Text("Model").tag(DriverDimension.model)
                            Text("Person").tag(DriverDimension.person)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        if c.drivers.isEmpty { Text(Fmt.noData).foregroundStyle(.secondary) }
                        ForEach(c.drivers) { d in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(d.name).font(.callout)
                                    if let o = d.orgName { Text(o).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Text(d.shareText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                Text(d.amountText).font(.callout).monospacedDigit()
                            }
                        }
                    }
                    Card("Spikes") {
                        if c.spikes.isEmpty {
                            Text("No spikes in the last 7 days.").font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(c.spikes) { s in
                            VStack(alignment: .leading, spacing: 1) {
                                Label(s.text, systemImage: "bolt.fill").font(.callout).foregroundStyle(.orange)
                                Text(s.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func projection(_ p: ProjectionView) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(p.projection.projectedByRunRate.map(Fmt.usd) ?? Fmt.noData).font(.title3.weight(.semibold)).monospacedDigit()
                Text("Run rate, last \(p.projection.runRateDays) covered days").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(p.projection.projectedByElapsedFraction.map(Fmt.usd) ?? Fmt.noData).font(.title3.weight(.semibold)).monospacedDigit()
                Text("Elapsed fraction, \(Fmt.percent(p.projection.elapsedFraction * 100)) of the month").font(.caption).foregroundStyle(.secondary)
            }
            if let b = p.budget, let proj = p.projection.projectedByRunRate ?? p.projection.projectedByElapsedFraction {
                let f = min(max(Fmt.chartValue(proj / b.amount), 0), 1)
                BudgetProgress(fraction: f, exceeded: proj > b.amount)
                Text(p.budgetNote ?? "").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Wraps chips onto several lines.
struct FlowRow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { content } }
    }
}
