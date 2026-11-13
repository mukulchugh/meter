import MeterCore
import SwiftUI

/// The "Plan usage" screen: subscription allowance for Claude Code and Codex. Never spend, never summed with it.
struct PlanUsageView: View {
    let model: AppModel

    var body: some View {
        let c = PlanUsageContent(plans: model.planUsage, now: model.now)
        Screen {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(PlanLabel.sectionTitle).font(.title3.weight(.semibold))
                    Label(PlanLabel.basis, systemImage: "person.crop.circle").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await model.refreshPlanUsage() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            ForEach(c.rows) { row in
                PlanCard(row: row)
            }
            Card("Claude Code hook") {
                ClaudeHookSection(
                    status: model.claudeHookStatus,
                    preview: { model.previewClaudeHook() },
                    enable: { await model.enableClaudeHook() },
                    disable: { await model.disableClaudeHook() })
            }
            Text("Plan usage is a percentage of a subscription allowance. It has no dollar value and is never added to API spend.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PlanCard: View {
    let row: PlanRow

    var body: some View {
        Card(row.title) {
            HStack {
                Text(PlanLabel.basis).font(.caption).foregroundStyle(.secondary)
                Spacer()
                PlanStateBadge(row: row)
            }
            if row.windows.isEmpty {
                Text(row.stateDetail).font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(row.windows) { w in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(w.name).font(.callout.weight(.medium))
                            Spacer()
                            Text(w.percentText).font(.callout).monospacedDigit()
                        }
                        BudgetProgress(fraction: w.fraction, exceeded: w.exceeded)
                        if let r = w.resetText { Text("Resets \(r)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if row.state != .ok { Text(row.stateDetail).font(.caption).foregroundStyle(.secondary) }
                if let u = row.updatedText { Text(u).font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }
}

struct PlanStateBadge: View {
    let row: PlanRow

    private var tone: Tone {
        switch row.state {
        case .ok: .good
        case .waiting, .resetPending, .stale: .caution
        case .limitReached, .error, .notLoggedIn: .bad
        case .notInstalled, .notEnabled, .noPlanLimits: .muted
        }
    }

    var body: some View {
        Text(row.stateLabel).font(.caption).foregroundStyle(tone.color)
            .help(row.stateDetail)
            .accessibilityLabel("\(row.stateLabel). \(row.stateDetail)")
    }
}

/// Enable and Disable for Meter's Claude Code status line hook. Nothing is written until the user confirms
/// the shown change. Plain values and closures only (no environment).
struct ClaudeHookSection: View {
    let status: ClaudeHookStatus
    let preview: () -> Result<StatusLineChange, StatusLineError>
    let enable: () async -> String?
    let disable: () async -> String?
    @State private var pending: StatusLineChange?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch status {
            case .off:
                Text("Claude Code shows your plan limits to a status line command. Meter can add a small helper there that records them to a file in Meter's own folder. Meter changes nothing until you press Enable.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Enable…") {
                    switch preview() {
                    case .success(let c): error = nil; pending = c
                    case .failure(let e): error = e.message
                    }
                }.disabled(busy)
            case .on:
                Label("On", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green)
                Text("The helper records your plan limits and passes your previous status line through. Readings update only while Claude Code is in use.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Disable") { run(disable) }.disabled(busy)
            case .changedElsewhere:
                Label("Changed outside Meter", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                Text("Claude Code's settings no longer point at Meter's helper. Disable clears Meter's record and leaves your settings as they are.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Disable") { run(disable) }.disabled(busy)
            }
            if let error { Label(error, systemImage: "xmark.octagon.fill").font(.callout).foregroundStyle(.red) }
        }
        .sheet(isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Turn on the Claude Code hook").font(.headline)
                Text(pending?.summary ?? "").font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { pending = nil }.keyboardShortcut(.cancelAction)
                    Button("Enable") { pending = nil; run(enable) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(width: 520)
        }
    }

    private func run(_ action: @escaping () async -> String?) {
        busy = true
        Task {
            error = await action()
            busy = false
        }
    }
}
