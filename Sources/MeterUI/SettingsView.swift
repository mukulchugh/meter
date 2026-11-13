import MeterCore
import SwiftUI

/// Scene root for Settings. Reads the environment; the form gets plain values and closures.
public struct SettingsRoot: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        SettingsForm(
            metric: model.menuMetric, scope: model.scope, orgs: model.snapshot.orgs, minutes: model.backgroundMinutes,
            launchAtLogin: model.launchAtLogin,
            setMetric: { model.setMenuMetric($0) },
            setScope: { s in Task { await model.setScope(s) } },
            setMinutes: { m in Task { await model.setBackgroundMinutes(m) } },
            setLaunch: { model.setLaunchAtLogin($0) })
    }
}

struct SettingsForm: View {
    let metric: MenuMetric
    let scope: Scope
    let orgs: [Org]
    let minutes: Int
    let launchAtLogin: Bool
    let setMetric: @MainActor @Sendable (MenuMetric) -> Void
    let setScope: @MainActor @Sendable (Scope) -> Void
    let setMinutes: @MainActor @Sendable (Int) -> Void
    let setLaunch: @MainActor @Sendable (Bool) -> Void

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
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding(.vertical, 8)
    }
}
