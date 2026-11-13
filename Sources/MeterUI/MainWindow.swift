import MeterCore
import SwiftUI

/// Scene root for the main window. Reads the environment; every child gets plain values and closures.
public struct MainWindowRoot: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $model.selection) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            Group {
                switch model.selection {
                case .overview: OverviewView(model: model)
                case .people: PeopleView(model: model)
                case .keys: KeysProjectsView(model: model)
                case .models: ModelsView(model: model)
                case .budgets: BudgetsView(model: model)
                case .connections: ConnectionsView(model: model)
                case .export: ExportView(model: model)
                }
            }
            .navigationTitle(model.selection.title)
            .toolbar {
                ToolbarItem {
                    ScopeMenu(orgs: model.snapshot.orgs, scope: model.scope) { s in Task { await model.setScope(s) } }
                }
                ToolbarItem {
                    Button { Task { await model.refreshAll() } } label: {
                        if model.isRefreshing { ProgressView().controlSize(.small) } else { Label("Refresh", systemImage: "arrow.clockwise") }
                    }
                    .disabled(model.isRefreshing)
                }
            }
            .safeAreaInset(edge: .top) {
                if let m = model.message {
                    HStack {
                        Label(m, systemImage: "exclamationmark.triangle").font(.callout)
                        Spacer()
                        Button("Dismiss") { model.dismissMessage() }
                    }
                    .padding(10).background(.thinMaterial)
                }
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .onAppear { model.surface(.window, visible: true) }
        .onDisappear { model.surface(.window, visible: false) }
    }
}

struct ScopeMenu: View {
    let orgs: [Org]
    let scope: Scope
    let choose: @MainActor @Sendable (Scope) -> Void

    var body: some View {
        Picker("Scope", selection: Binding(get: { scope }, set: choose)) {
            Text("All organizations").tag(Scope.all)
            ForEach(orgs) { Text($0.displayName).tag(Scope.org($0.id)) }
        }
        .pickerStyle(.menu)
        .help("Which organizations the numbers cover")
    }
}

/// Shown by every screen before the first organization exists.
struct NoOrgsView: View {
    let openConnections: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            EmptyState(symbol: "link", title: "No organizations yet",
                       detail: "Add an Anthropic or OpenAI organization with an admin key to see spend.")
            Button("Add an organization", action: openConnections).buttonStyle(.borderedProminent)
        }
    }
}

struct Screen<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
