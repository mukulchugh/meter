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
                case .planUsage: PlanUsageView(model: model)
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
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if let banner = model.previewBanner {
                        PreviewBannerView(banner: banner) { Task { await model.exitPreview() } }
                    }
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

/// The two ways out of an empty state: connect a real organization, or look at sample data first.
struct EmptyStateActions: View {
    let add: () -> Void
    let preview: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Button("Add organization", action: add).buttonStyle(.borderedProminent)
            Button("Preview with sample data", action: preview)
        }
    }
}

/// Shown by every screen before the first organization exists.
struct NoOrgsView: View {
    let add: () -> Void
    let preview: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            EmptyState(symbol: "link", title: "No organizations yet",
                       detail: "Add an Anthropic or OpenAI organization with an admin key to see spend, or look around with sample data first.")
            EmptyStateActions(add: add, preview: preview)
        }
    }
}

/// The persistent notice while sample data is on. Plain values and closures only.
struct PreviewBannerView: View {
    let banner: PreviewBanner
    let exit: () -> Void
    var body: some View {
        HStack {
            Label(banner.text, systemImage: "eye").font(.callout.weight(.medium))
            Spacer()
            Button(banner.exitTitle, action: exit)
        }
        .padding(10)
        .background(Color.orange.opacity(0.18))
        .accessibilityElement(children: .combine)
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
