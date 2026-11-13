import MeterCore
import SwiftUI

struct ConnectionsView: View {
    let model: AppModel
    @State private var adding = false
    @State private var rotating: ConnectionRow?
    @State private var removing: ConnectionRow?

    var body: some View {
        let c = ConnectionsContent(snapshot: model.snapshot, now: model.now)
        Screen {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Organizations").font(.title3.weight(.semibold))
                    Text("Admin keys are stored in the Keychain. Meter reads cost and usage only.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add organization", systemImage: "plus") { adding = true }.buttonStyle(.borderedProminent)
            }
            if c.rows.isEmpty {
                Card {
                    Text("No organizations yet.").font(.callout).foregroundStyle(.secondary)
                    EmptyStateActions(add: { adding = true }, preview: { Task { await model.enterPreview() } })
                }
            }
            ForEach(c.rows) { r in
                ConnectionCard(row: r, rotate: { rotating = r }, remove: { removing = r })
            }
            Card("Where to create an admin key") {
                ForEach(Provider.allCases, id: \.self) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.displayName).font(.callout.weight(.medium))
                        Text(ConnectionHelp.steps(for: p)).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Label(ConnectionHelp.organizationNote, systemImage: "info.circle").font(.callout)
            }
        }
        .onAppear(perform: consumeAddRequest)
        .onChange(of: model.addOrganizationRequested) { consumeAddRequest() }
        .sheet(isPresented: $adding) {
            AddOrganizationForm(
                save: { draft in await model.addOrganization(draft) },
                close: { adding = false })
        }
        .sheet(item: $rotating) { row in
            RotateKeyForm(
                orgName: row.org.displayName, provider: row.org.provider,
                save: { key in await model.rotateKey(orgId: row.id, newKey: key) },
                close: { rotating = nil })
        }
        .confirmationDialog("Remove this organization?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { r in
            Button("Remove \(r.org.displayName)", role: .destructive) { Task { await model.removeOrganization(id: r.id) } }
        } message: { _ in
            Text("This deletes its stored key and its local history. Provider data is not touched.")
        }
    }
}

extension ConnectionsView {
    /// An empty state elsewhere asked for the add form.
    func consumeAddRequest() {
        guard model.addOrganizationRequested else { return }
        model.addOrganizationRequested = false
        adding = true
    }
}

struct ConnectionCard: View {
    let row: ConnectionRow
    let rotate: () -> Void
    let remove: () -> Void
    var body: some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.org.displayName).font(.callout.weight(.medium))
                    Text("\(row.org.provider.displayName), \(row.lastReportText)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                StateBadge(state: row.state)
                Button("Rotate key", action: rotate)
                Button("Remove", role: .destructive, action: remove)
            }
            if let e = row.errorText { Text(e).font(.caption).foregroundStyle(.red) }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(row.dimensions) { d in
                    HStack { Text(d.name).font(.caption); Spacer(); StateBadge(state: d.state) }
                }
            }
        }
    }
}

struct AddOrganizationForm: View {
    @State private var draft = ConnectionDraft()
    @State private var result: ConnectionResult?
    @State private var saving = false
    let save: (ConnectionDraft) async -> ConnectionResult?
    let close: () -> Void

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $draft.provider) {
                    ForEach(Provider.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                TextField("Display name", text: $draft.displayName, prompt: Text(draft.provider.displayName))
                SecureField("API key", text: $draft.adminKey, prompt: Text("Admin key or user API key"))
                if let problem = draft.errors.first, !draft.adminKey.isEmpty {
                    Label(problem, systemImage: "xmark.octagon.fill").font(.callout).foregroundStyle(.red)
                } else if let note = draft.warning {
                    Label(note, systemImage: "info.circle.fill").font(.callout).foregroundStyle(.secondary)
                }
                Text(ConnectionHelp.steps(for: draft.provider)).font(.caption).foregroundStyle(.secondary)
                Text(ConnectionHelp.organizationNote).font(.caption).foregroundStyle(.secondary)
            }
            if let r = result {
                Section("Result") {
                    HStack { StateBadge(state: r.state); Text(r.message).font(.callout) }
                }
            }
            HStack {
                Spacer()
                Button(result?.succeeded == true ? "Done" : "Cancel", action: close).keyboardShortcut(.cancelAction)
                if saving {
                    ProgressView().controlSize(.small)
                    Text("Checking with \(draft.provider.displayName)…").font(.callout).foregroundStyle(.secondary)
                }
                if result?.succeeded != true {
                    Button("Save and refresh") {
                        saving = true
                        Task {
                            result = await save(draft) ?? ConnectionResult(orgId: "", state: .error, message: "Nothing was saved. Try again.", succeeded: false)
                            if result?.succeeded == true { draft.adminKey = "" }
                            saving = false
                        }
                    }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(draft.trimmedKey.isEmpty || saving)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
    }
}

struct RotateKeyForm: View {
    let orgName: String
    let provider: Provider
    let save: (String) async -> ConnectionResult?
    let close: () -> Void
    @State private var key = ""
    @State private var result: ConnectionResult?
    @State private var saving = false

    var body: some View {
        Form {
            Section("Rotate key for \(orgName)") {
                SecureField("New admin key", text: $key)
                Text("The old key is replaced in the Keychain. \(ConnectionHelp.steps(for: provider))").font(.caption).foregroundStyle(.secondary)
            }
            if let r = result { HStack { StateBadge(state: r.state); Text(r.message).font(.callout) } }
            HStack {
                Spacer()
                Button(result?.succeeded == true ? "Done" : "Cancel", action: close).keyboardShortcut(.cancelAction)
                if result?.succeeded != true {
                    Button("Save and refresh") {
                        saving = true
                        Task {
                            result = await save(key)
                            key = ""
                            saving = false
                        }
                    }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(key.isEmpty || saving)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
    }
}
