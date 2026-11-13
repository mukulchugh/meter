import MeterCore
import SwiftUI

struct ModelsView: View {
    let model: AppModel

    var body: some View {
        if model.snapshot.orgs.isEmpty {
            NoOrgsView { model.selection = .connections }
        } else {
            let c = ModelsContent(snapshot: model.snapshot, now: model.now, scope: model.scope)
            Screen {
                HStack(spacing: 8) {
                    Text("This month, \(c.periodText)").font(.callout).foregroundStyle(.secondary)
                    BasisTag(basis: .reported)
                }
                if c.rows.isEmpty {
                    EmptyState(symbol: "cpu", title: "No model spend yet", detail: "Spend by model appears after the first report.")
                } else {
                    Card("Share of spend") { ShareBars(rows: c.rows) }
                    Table(c.rows) {
                        TableColumn("Model") { r in
                            Text(r.name).foregroundStyle(r.isUnattributed ? .secondary : .primary)
                        }
                        .width(min: 160, ideal: 240)
                        TableColumn("Spend") { r in Text(r.amountText).monospacedDigit() }.width(100)
                        TableColumn("Share") { r in Text(r.shareText).monospacedDigit() }.width(70)
                    }
                    .frame(minHeight: 200)
                }
                Text(ModelsContent.tokensNote).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
