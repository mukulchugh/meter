import MeterCore
import SwiftUI

struct PeopleView: View {
    let model: AppModel

    var body: some View {
        if model.snapshot.orgs.isEmpty {
            NoOrgsView { model.selection = .connections }
        } else {
            let c = PeopleContent(snapshot: model.snapshot, now: model.now, scope: model.scope)
            Screen {
                HStack(spacing: 8) {
                    Text("This month, \(c.periodText)").font(.callout).foregroundStyle(.secondary)
                    BasisTag(basis: .reported)
                    Text("spend, merged by email").font(.caption).foregroundStyle(.secondary)
                }
                if c.rows.isEmpty {
                    EmptyState(symbol: "person.2", title: "No people yet",
                               detail: "Per-person spend appears once the providers report users and emails.")
                } else {
                    Table(c.rows) {
                        TableColumn("Person") { r in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.name)
                                if r.name != r.email { Text(r.email).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        .width(min: 150, ideal: 190)
                        TableColumn("Anthropic") { r in Text(r.anthropicText).monospacedDigit() }.width(80)
                        TableColumn("OpenAI") { r in Text(r.openaiText).monospacedDigit() }.width(80)
                        TableColumn("Total (reported)") { r in Text(r.totalText).fontWeight(.medium).monospacedDigit() }.width(100)
                        TableColumn("Sessions") { r in Text(r.sessionsText).monospacedDigit() }.width(60)
                        TableColumn("Lines") { r in Text(r.linesText).monospacedDigit() }.width(90)
                        TableColumn("Commits") { r in Text(r.commitsText).monospacedDigit() }.width(60)
                        TableColumn("PRs") { r in Text(r.pullRequestsText).monospacedDigit() }.width(40)
                        TableColumn(PeopleContent.estimateColumnTitle) { r in
                            HStack(spacing: 4) {
                                Text(r.estimatedCostText).monospacedDigit().foregroundStyle(.secondary)
                                if r.activity != nil { BasisTag(basis: .estimate) }
                            }
                        }
                        .width(min: 170, ideal: 190)
                    }
                    .frame(minHeight: 260)
                    Text("Claude Code columns come from the Claude Code analytics API. Its cost is an estimate and is never added to reported spend.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !c.apiActors.isEmpty {
                    Card("Claude Code through API keys") {
                        ForEach(c.apiActors, id: \.id) { a in
                            HStack {
                                Text(a.id).font(.callout)
                                Spacer()
                                Text("\(Fmt.count(a.sessions)) sessions").font(.caption).foregroundStyle(.secondary)
                                Text(Fmt.usd(a.estimatedCost)).font(.callout).monospacedDigit()
                                BasisTag(basis: .estimate)
                            }
                        }
                    }
                }
                Card("Not matched to a person") {
                    if c.unmatched.isEmpty {
                        Text("Every attributed amount is tied to an email.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(c.unmatched) { u in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(u.name).font(.callout)
                                Text("\(u.orgName), \(u.reason)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(u.amountText).font(.callout).monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}
