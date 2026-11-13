import MeterCore
import SwiftUI

struct BudgetEditorItem: Identifiable {
    let id = UUID()
    var draft: BudgetDraft
}

struct BudgetsView: View {
    let model: AppModel
    @State private var editing: BudgetEditorItem?
    @State private var deleting: BudgetRow?

    var body: some View {
        let c = BudgetsContent(snapshot: model.snapshot, now: model.now)
        Screen {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Monthly budgets").font(.title3.weight(.semibold))
                    Text("Budgets are \(BudgetBar.note). Meter notifies at 50, 80 and 100 percent and on spikes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("New budget", systemImage: "plus") { editing = BudgetEditorItem(draft: BudgetDraft()) }
                    .buttonStyle(.borderedProminent)
            }
            if model.snapshot.orgs.isEmpty {
                Text("Add an organization first so budgets have spend to track.").font(.callout).foregroundStyle(.secondary)
            }
            if c.budgets.isEmpty {
                Card { Text("No budgets yet. Creating the first one asks to allow notifications.").font(.callout).foregroundStyle(.secondary) }
            }
            ForEach(c.budgets) { b in
                BudgetCard(row: b, edit: { editing = BudgetEditorItem(draft: BudgetDraft(b.budget)) }, remove: { deleting = b })
            }

            Text("OpenAI limits").font(.title3.weight(.semibold)).padding(.top, 8)
            Text("Read from OpenAI. Meter shows them and cannot change them.").font(.caption).foregroundStyle(.secondary)
            if c.limits.isEmpty {
                Card { Text("No OpenAI limits found.").font(.callout).foregroundStyle(.secondary) }
            }
            ForEach(c.limits) { l in
                Card {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(l.title), \(l.orgName)").font(.callout.weight(.medium))
                            Text(l.kindText).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(l.usedText) of \(l.thresholdText), \(l.percentText)").font(.callout).monospacedDigit()
                    }
                    BudgetProgress(fraction: l.fraction, exceeded: l.fraction >= 1)
                    Text(l.projectedText).font(.caption).foregroundStyle(.secondary)
                }
            }

            Text("Prepaid balance").font(.title3.weight(.semibold)).padding(.top, 8)
            if c.openAIOrgs.isEmpty {
                Card { Text("Add an OpenAI organization to track a prepaid balance.").font(.callout).foregroundStyle(.secondary) }
            }
            ForEach(c.prepaid) { p in
                PrepaidCard(row: p, save: { amount, date in Task { await model.setPrepaid(orgId: p.id, amount: amount, enteredAt: date) } })
            }
        }
        .sheet(item: $editing) { item in
            BudgetForm(
                initial: item.draft, projects: c.projectChoices,
                save: { draft in await model.saveBudget(draft) },
                close: { editing = nil })
        }
        .confirmationDialog("Delete this budget?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { b in
            Button("Delete \(b.budget.name)", role: .destructive) { Task { await model.deleteBudget(id: b.id) } }
        }
    }
}

struct BudgetCard: View {
    let row: BudgetRow
    let edit: () -> Void
    let remove: () -> Void
    var body: some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.budget.name).font(.callout.weight(.medium))
                    Text("\(row.scopeText), alerts at \(row.thresholdsText)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(row.usedText) of \(row.targetText), \(row.percentText)").font(.callout).monospacedDigit()
                Button("Edit", action: edit)
                Button("Delete", role: .destructive, action: remove)
            }
            BudgetProgress(fraction: row.fraction, exceeded: row.exceeded)
            HStack {
                Text(row.projectedText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(BudgetBar.note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct PrepaidCard: View {
    let row: PrepaidRow
    let save: (Decimal, Date) -> Void
    @State private var amountText = ""
    @State private var date = Date()

    var body: some View {
        Card(row.orgName) {
            if let remaining = row.remainingText {
                HStack(alignment: .firstTextBaseline) {
                    Text(remaining).font(.title3.weight(.semibold)).monospacedDigit()
                    Text("remaining").foregroundStyle(.secondary)
                    BasisTag(basis: .estimate)
                }
                Text([row.daysLeftText, row.runOutText, row.enteredText].compactMap { $0 }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
                if let n = row.partialNote { Text(n).font(.caption).foregroundStyle(.orange) }
            } else {
                Text("No balance entered.").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Balance in dollars", text: $amountText).frame(width: 150)
                DatePicker("As of", selection: $date, in: ...Date(), displayedComponents: .date)
                Button("Save") {
                    if let a = BudgetDraft.parseAmount(amountText), a >= 0 { save(a, date); amountText = "" }
                }
                .disabled(BudgetDraft.parseAmount(amountText) == nil)
            }
            Text("This is an \(PrepaidRow.label), minus reported spend since the date.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct BudgetForm: View {
    @State var draft: BudgetDraft
    @State private var errors = BudgetFormErrors(fields: [:])
    let projects: [ProjectChoice]
    let save: (BudgetDraft) async -> BudgetFormErrors?
    let close: () -> Void

    init(initial: BudgetDraft, projects: [ProjectChoice], save: @escaping (BudgetDraft) async -> BudgetFormErrors?,
         close: @escaping () -> Void) {
        _draft = State(initialValue: initial)
        self.projects = projects
        self.save = save
        self.close = close
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                fieldError(.name)
                TextField("Monthly amount in dollars", text: $draft.amountText)
                fieldError(.amount)
                Picker("Applies to", selection: $draft.scopeKind) {
                    ForEach(BudgetScopeKind.allCases) { Text($0.title).tag($0) }
                }
                if draft.scopeKind == .tag {
                    Picker("Tag", selection: $draft.tag) { ForEach(TagKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                }
                if draft.scopeKind == .project {
                    Picker("Project", selection: Binding(
                        get: { projects.first { $0.orgId == draft.projectOrgId && $0.projectId == draft.projectId } },
                        set: { draft.projectOrgId = $0?.orgId ?? ""; draft.projectId = $0?.projectId ?? "" })) {
                        Text("Choose").tag(ProjectChoice?.none)
                        ForEach(projects) { Text($0.title).tag(Optional($0)) }
                    }
                }
                fieldError(.scope)
            }
            Section("Notify at") {
                HStack {
                    ForEach(BudgetDraft.allowedThresholds, id: \.self) { t in
                        Toggle("\(t)%", isOn: Binding(
                            get: { draft.thresholds.contains(t) },
                            set: { on in if on { draft.thresholds.insert(t) } else { draft.thresholds.remove(t) } }))
                    }
                }
                fieldError(.thresholds)
                Text("Alert only, does not stop spend.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        if let e = await save(draft) { errors = e } else { close() }
                    }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding(.vertical, 8)
    }

    @ViewBuilder private func fieldError(_ f: BudgetField) -> some View {
        if let m = errors.fields[f] { Text(m).font(.caption).foregroundStyle(.red) }
    }
}
