import AppKit
import MeterCore
import SwiftUI

public enum MeterWindowID { public static let main = "main" }

@MainActor func activateApp() { NSApplication.shared.activate() }

/// The menu bar label: one stable metric, an attention glyph when data is missing or unhealthy.
public struct MenuBarLabelView: View {
    let title: MenuBarTitle
    let isPreview: Bool
    public init(title: MenuBarTitle, isPreview: Bool = false) {
        self.title = title
        self.isPreview = isPreview
    }
    public var body: some View {
        HStack(spacing: 4) {
            if isPreview {
                Image(systemName: "eye")
            } else {
                Image(nsImage: Brand.glyph(attention: title.showsAttention))
            }
            // Sample numbers must never pass for real spend in the menu bar.
            if isPreview { Text("Sample") } else if let text = title.text { Text(text).monospacedDigit() }
        }
        .accessibilityLabel(isPreview ? "Meter, sample data" : title.accessibilityLabel)
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
            content: model.popover, plans: PlanUsageContent(plans: model.planUsage, now: model.now).popoverRows,
            isRefreshing: model.isRefreshing, startupNote: model.startupNote,
            banner: model.previewBanner,
            addOrganization: { model.beginAddOrganization(); openWindow(id: MeterWindowID.main); activateApp() },
            startPreview: { Task { await model.enterPreview() } },
            exitPreview: { Task { await model.exitPreview() } },
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
    /// Plan usage rows worth showing (your plan, not API spend). Empty when no tool is set up.
    var plans: [PlanRow] = []
    let isRefreshing: Bool
    let startupNote: String?
    let banner: PreviewBanner?
    let addOrganization: () -> Void
    let startPreview: () -> Void
    let exitPreview: () -> Void
    let openMeter: () -> Void
    let refresh: () -> Void
    let openSettings: () -> Void

    var body: some View {
        if !content.hasOrgs && banner == nil {
            emptyState
        } else {
            populated
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let startupNote { Text(startupNote).font(.caption).foregroundStyle(.orange) }
            EmptyState(symbol: "link", title: "No organizations yet",
                       detail: "Add an Anthropic or OpenAI organization to see spend, or look around with sample data.")
            VStack(spacing: 8) {
                Button(action: addOrganization) { Text("Add organization").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                Button(action: startPreview) { Text("Preview with sample data").frame(maxWidth: .infinity) }
            }
            Divider()
            HStack {
                Spacer()
                Button("Settings", action: openSettings)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private var populated: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let banner { PreviewBannerView(banner: banner, exit: exitPreview).clipShape(RoundedRectangle(cornerRadius: 8)) }
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

            // Plan usage: one quiet line per tool, labelled as the plan and kept out of the spend above.
            if !plans.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(PlanLabel.sectionTitle).font(.caption.weight(.semibold))
                        Text(PlanLabel.basis).font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(plans) { p in
                        Text(p.summary).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            .accessibilityLabel("\(PlanLabel.basis). \(p.summary)")
                    }
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
