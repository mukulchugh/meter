import AppKit
import MeterCore
import SwiftUI

public enum MeterWindowID { public static let main = "main" }

@MainActor func activateApp() { NSApplication.shared.activate() }

/// The menu bar label: one stable metric, an attention glyph when data is missing or unhealthy.
public struct MenuBarLabelView: View {
    let title: MenuBarTitle
    public init(title: MenuBarTitle) { self.title = title }
    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: title.showsAttention ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.50percent")
            if let text = title.text { Text(text).monospacedDigit() }
        }
        .accessibilityLabel(title.accessibilityLabel)
    }
}

/// Scene root for the popover. One of the few views that reads the environment.
public struct PopoverRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    public init() {}

    public var body: some View {
        PopoverView(
            content: model.popover, isRefreshing: model.isRefreshing, startupNote: model.startupNote,
            openMeter: { openWindow(id: MeterWindowID.main); activateApp() },
            refresh: { Task { await model.refreshAll() } },
            openSettings: { openSettings(); activateApp() })
            .onAppear { model.surface(.popover, visible: true) }
            .onDisappear { model.surface(.popover, visible: false) }
    }
}

/// Light on purpose: no tables, no legends. Scope, total, orgs, a week, the budget, three buttons.
struct PopoverView: View {
    let content: PopoverContent
    let isRefreshing: Bool
    let startupNote: String?
    let openMeter: () -> Void
    let refresh: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 1. Scope and reporting time
            VStack(alignment: .leading, spacing: 2) {
                Text(content.scopeLabel).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(content.reportedText).font(.caption).foregroundStyle(.secondary)
            }
            if let startupNote { Text(startupNote).font(.caption).foregroundStyle(.orange) }

            // 2. Today, split App / Team / Untagged
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Today").font(.subheadline)
                    BasisTag(basis: .reported)
                }
                ReadingText(reading: content.today, font: .system(size: 30, weight: .semibold))
                if content.today.state != .missing { SplitBar(rows: content.split) }
            }

            // 3. One row per org
            if !content.orgs.isEmpty {
                VStack(spacing: 8) {
                    ForEach(content.orgs) { row in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.name).font(.callout)
                                Text(row.freshness).font(.caption).foregroundStyle(StateInfo.of(row.state).tone.color)
                            }
                            Spacer()
                            Text(row.amountText).font(.callout.weight(.medium)).monospacedDigit()
                        }
                    }
                }
            }

            // 4. Seven days
            if content.week.contains(where: { $0.value != nil }) {
                DailyBars(points: content.week, height: 70)
            }

            // 5. Budget
            if let b = content.budget {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(b.name).font(.caption.weight(.medium))
                        Spacer()
                        Text("\(b.usedText) of \(b.targetText), \(b.percentText)").font(.caption).monospacedDigit()
                    }
                    BudgetProgress(fraction: b.fraction, exceeded: b.exceeded)
                    Text("Monthly budget, \(BudgetBar.note)").font(.caption2).foregroundStyle(.secondary)
                }
            }

            Divider()
            // 6. Buttons
            HStack {
                Button("Open Meter", action: openMeter).buttonStyle(.borderedProminent)
                Button(action: refresh) {
                    if isRefreshing { ProgressView().controlSize(.small) } else { Text("Refresh") }
                }
                .disabled(isRefreshing)
                Spacer()
                Button("Settings", action: openSettings)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
