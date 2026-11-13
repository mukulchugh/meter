import MeterCore
import SwiftUI

struct KeysProjectsView: View {
    let model: AppModel

    var body: some View {
        if model.snapshot.orgs.isEmpty {
            NoOrgsView(add: { model.beginAddOrganization() }, preview: { Task { await model.enterPreview() } })
        } else {
            let c = KeysContent(snapshot: model.snapshot, now: model.now, scope: model.scope, dismissed: model.dismissedSuggestions)
            let now = model.now
            let setTag: @MainActor @Sendable (KeyRow, TagKind) -> Void = { row, kind in
                Task { await model.setTag(orgId: row.orgId, target: row.tagTarget, targetId: row.targetId, kind: kind) }
            }
            Screen {
                if !c.suggestions.isEmpty {
                    Card("Suggested tags") {
                        Text("Based on names. Nothing changes until you accept.").font(.caption).foregroundStyle(.secondary)
                        ForEach(c.suggestions) { s in
                            SuggestionLine(
                                row: s,
                                accept: { Task { await model.accept(s.suggestion) } },
                                dismiss: { Task { await model.dismiss(s.suggestion) } })
                        }
                    }
                }
                if c.rows.isEmpty {
                    EmptyState(symbol: "key", title: "No keys or projects yet",
                               detail: "They appear after the first refresh reads names from the provider.")
                } else {
                    Table(c.rows) {
                        TableColumn("Name") { r in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.name)
                                Text(r.kindText).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .width(min: 130, ideal: 170)
                        TableColumn("Organization") { r in Text(r.orgName) }.width(min: 90, ideal: 120)
                        TableColumn("Tag") { r in
                            Picker("Tag", selection: Binding(get: { r.tag }, set: { setTag(r, $0) })) {
                                ForEach(TagKind.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                        }
                        .width(100)
                        TableColumn("This month") { r in Text(r.monthText).monospacedDigit() }.width(90)
                        TableColumn("Today") { r in Text(r.todayText).monospacedDigit().foregroundStyle(r.today == nil ? .secondary : .primary) }.width(80)
                        TableColumn("Last used") { r in Text(r.lastUsedText(now: now)).foregroundStyle(.secondary) }.width(90)
                        TableColumn("Owner") { r in Text(r.ownerText).foregroundStyle(r.owner == nil ? .secondary : .primary) }.width(min: 80, ideal: 110)
                        TableColumn("Watch") { r in
                            if let f = r.flagText {
                                Label(f, systemImage: r.isRunaway ? "bolt.fill" : "moon.zzz")
                                    .font(.caption).foregroundStyle(r.isRunaway ? .orange : .secondary)
                            }
                        }
                        .width(min: 100, ideal: 120)
                    }
                    .frame(minHeight: 320)
                    Text("Anthropic reports a key's spend once the day closes, so Today is empty for its keys. A key's tag wins over its project's.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct SuggestionLine: View {
    let row: SuggestionRow
    let accept: () -> Void
    let dismiss: () -> Void
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(row.name) as \(row.suggested.title)").font(.callout)
                Text("\(row.orgName), \(row.reason)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Dismiss", action: dismiss)
            Button("Accept", action: accept).buttonStyle(.borderedProminent)
        }
    }
}
