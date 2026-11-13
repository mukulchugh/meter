import MeterCore
import SwiftUI

/// Scene root for Settings. Reads the environment; the form gets plain values and closures.
public struct SettingsRoot: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        SettingsForm(
            metric: model.menuMetric, scope: model.scope, orgs: model.snapshot.orgs, minutes: model.backgroundMinutes,
            launchAtLogin: model.launchAtLogin, previewing: model.isPreviewing, canPreview: model.canPreview,
            setPreview: { on in Task { await model.setPreview(on) } },
            setMetric: { model.setMenuMetric($0) },
            setScope: { s in Task { await model.setScope(s) } },
            setMinutes: { m in Task { await model.setBackgroundMinutes(m) } },
            setLaunch: { model.setLaunchAtLogin($0) },
            claudeHook: model.claudeHookStatus,
            previewHook: { model.previewClaudeHook() },
            enableHook: { await model.enableClaudeHook() },
            disableHook: { await model.disableClaudeHook() })
    }
}

struct SettingsForm: View {
    let metric: MenuMetric
    let scope: Scope
    let orgs: [Org]
    let minutes: Int
    let launchAtLogin: Bool
    let previewing: Bool
    let canPreview: Bool
    let setPreview: @MainActor @Sendable (Bool) -> Void
    let setMetric: @MainActor @Sendable (MenuMetric) -> Void
    let setScope: @MainActor @Sendable (Scope) -> Void
    let setMinutes: @MainActor @Sendable (Int) -> Void
    let setLaunch: @MainActor @Sendable (Bool) -> Void
    let claudeHook: ClaudeHookStatus
    let previewHook: () -> Result<StatusLineChange, StatusLineError>
    let enableHook: () async -> String?
    let disableHook: () async -> String?

    var body: some View {
        Form {
            Picker("Menu bar shows", selection: Binding(get: { metric }, set: setMetric)) {
                ForEach(MenuMetric.allCases) { Text($0.title).tag($0) }
            }
            Picker("Default scope", selection: Binding(get: { scope }, set: setScope)) {
                Text("All organizations").tag(Scope.all)
                ForEach(orgs) { Text($0.displayName).tag(Scope.org($0.id)) }
            }
            Picker("Background refresh", selection: Binding(get: { minutes }, set: setMinutes)) {
                ForEach([15, 30, 60], id: \.self) { Text("Every \($0) minutes").tag($0) }
            }
            Text("While Meter is open it refreshes every minute.").font(.caption).foregroundStyle(.secondary)
            Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunch))
            Section("Plan usage") {
                Text("\(PlanLabel.basis). Codex needs nothing: Meter asks the codex app on this Mac, using your own login.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Claude Code").font(.callout.weight(.medium))
                ClaudeHookSection(status: claudeHook, preview: previewHook, enable: enableHook, disable: disableHook)
            }
            Toggle("Preview with sample data", isOn: Binding(get: { previewing }, set: setPreview)).disabled(!canPreview)
            Text(canPreview ? "Shows a made-up company so you can look around. Nothing is saved to your real data and no keys are used."
                 : "Sample data is only offered before an organization is connected.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
    }
}
