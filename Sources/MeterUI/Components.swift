import Charts
import MeterCore
import SwiftUI

extension Tone {
    var color: Color {
        switch self {
        case .good: .green
        case .neutral: .accentColor
        case .caution: .orange
        case .bad: .red
        case .muted: .secondary
        }
    }
}

// MARK: States, one explicit view each (UX-RESEARCH section 9)

struct ConnectedBadge: View { var body: some View { StateLabel(state: .connected) } }
struct FreshBadge: View { var body: some View { StateLabel(state: .fresh) } }
struct DelayedBadge: View { var body: some View { StateLabel(state: .delayed) } }
struct StaleBadge: View { var body: some View { StateLabel(state: .stale) } }
struct ErrorBadge: View { var body: some View { StateLabel(state: .error) } }
struct UnavailableDimensionBadge: View { var body: some View { StateLabel(state: .unavailableDimension) } }
struct NoActivityBadge: View { var body: some View { StateLabel(state: .noActivity) } }

struct StateLabel: View {
    let state: FreshnessState
    var body: some View {
        let info = StateInfo.of(state)
        Label(info.label, systemImage: info.symbol)
            .font(.caption)
            .foregroundStyle(info.tone.color)
            .help(info.detail)
            .accessibilityLabel("\(info.label). \(info.detail)")
    }
}

/// Picks the badge for a state. The switch is exhaustive on purpose.
struct StateBadge: View {
    let state: FreshnessState
    var body: some View {
        switch state {
        case .connected: ConnectedBadge()
        case .fresh: FreshBadge()
        case .delayed: DelayedBadge()
        case .stale: StaleBadge()
        case .error: ErrorBadge()
        case .unavailableDimension: UnavailableDimensionBadge()
        case .noActivity: NoActivityBadge()
        }
    }
}

/// A reading with its state. Missing never looks like zero.
struct ReadingText: View {
    let reading: Reading
    var font: Font = .title2.weight(.semibold)
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Fmt.reading(reading)).font(font).monospacedDigit()
            switch reading.state {
            case .value: EmptyView()
            case .noActivity: Text("No activity").font(.caption).foregroundStyle(.secondary)
            case .partial:
                Label("Some data is missing", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            case .missing:
                Label("Not reported yet", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

enum BasisKind { case reported, estimate }

/// "Reported" or "Estimate", beside a number. The two are never added together.
struct BasisTag: View {
    let basis: BasisKind
    var body: some View {
        Text(basis == .reported ? Fmt.reportedLabel : Fmt.estimateLabel)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(basis == .reported ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.18), in: Capsule())
            .foregroundStyle(basis == .reported ? Color.accentColor : Color.secondary)
            .help(basis == .reported ? Reading.basisLabel : "Estimated by the provider. Not part of any reported total.")
    }
}

struct Card<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Text(title).font(.headline) }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SplitBar: View {
    let rows: [SplitRow]
    var body: some View {
        HStack(spacing: 18) {
            ForEach(rows) { r in
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.title).font(.caption).foregroundStyle(.secondary)
                    Text(r.text).font(.body.weight(.medium)).monospacedDigit()
                }
            }
        }
    }
}

struct BudgetProgress: View {
    let fraction: Double
    let exceeded: Bool
    var body: some View {
        ProgressView(value: fraction)
            .tint(exceeded ? .red : .accentColor)
            .accessibilityValue(Fmt.percent(fraction * 100))
    }
}

struct CoverageChipView: View {
    let chip: CoverageChip
    var body: some View {
        let info = StateInfo.of(chip.state)
        HStack(spacing: 5) {
            Image(systemName: info.symbol).foregroundStyle(info.tone.color)
            Text(chip.orgName).fontWeight(.medium)
            Text(chip.detail).foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .help(info.detail)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(detail))
    }
}

// MARK: Charts

struct DailyBars: View {
    let points: [ChartPoint]
    var height: CGFloat = 120
    var labelEvery = 1
    var body: some View {
        let shown = Set(points.enumerated().filter { $0.offset % labelEvery == 0 || $0.offset == points.count - 1 }.map(\.element.label))
        Chart(points) { p in
            if let v = p.value {
                BarMark(x: .value("Day", p.label), y: .value("USD", v))
                    .foregroundStyle(p.id == points.last?.id ? Color.accentColor : Color.accentColor.opacity(0.45))
                    .cornerRadius(2)
            }
        }
        .chartXScale(domain: points.map(\.label))
        .chartXAxis {
            AxisMarks(values: points.map(\.label)) { v in
                if let s = v.as(String.self), shown.contains(s) { AxisValueLabel() }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text("$\(Int(d))") } }
            }
        }
        .frame(height: height)
        .accessibilityLabel("Daily spend")
    }
}

struct CumulativeLine: View {
    let points: [ChartPoint]
    var body: some View {
        Chart(points) { p in
            if let v = p.value {
                LineMark(x: .value("Day", p.label), y: .value("USD", v)).foregroundStyle(Color.accentColor)
                AreaMark(x: .value("Day", p.label), y: .value("USD", v)).foregroundStyle(Color.accentColor.opacity(0.1))
            }
        }
        .chartXScale(domain: points.map(\.label))
        .chartXAxis {
            AxisMarks(values: points.enumerated().filter { $0.offset % 5 == 0 }.map(\.element.label)) { _ in AxisValueLabel() }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text("$\(Int(d))") } }
            }
        }
        .frame(height: 120)
        .accessibilityLabel("Cumulative spend this month")
    }
}

struct ShareBars: View {
    let rows: [ModelRow]
    var body: some View {
        Chart(rows) { r in
            BarMark(x: .value("Share", r.share * 100), y: .value("Model", r.name))
                .foregroundStyle(Color.accentColor)
                .annotation(position: .trailing) { Text(r.shareText).font(.caption).foregroundStyle(.secondary) }
        }
        .chartXScale(domain: 0...100)
        .chartXAxis(.hidden)
        .frame(height: CGFloat(max(rows.count, 1)) * 30 + 10)
        .accessibilityLabel("Share of spend by model")
    }
}
