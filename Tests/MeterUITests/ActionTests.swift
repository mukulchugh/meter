import Foundation
import MeterCore
import Testing
@testable import MeterUI

@Suite struct BudgetDraftTests {
    private func valid() -> BudgetDraft {
        var d = BudgetDraft()
        d.name = "Monthly"
        d.amountText = "5,000"
        return d
    }

    @Test func aValidOverallDraftBecomesABudget() throws {
        let b = try valid().validate().get()
        #expect(b.name == "Monthly")
        #expect(b.amount == 5000)
        #expect(b.scope == .overall)
        #expect(b.thresholds == [50, 80, 100])
    }

    @Test func amountParsesDollarsAndCommas() {
        #expect(BudgetDraft.parseAmount("$1,250.50") == dec("1250.50"))
        #expect(BudgetDraft.parseAmount("abc") == nil)
        #expect(BudgetDraft.parseAmount("") == nil)
        #expect(BudgetDraft.parseAmount("-5") == nil)
        #expect(BudgetDraft.parseAmount("1e3") == nil)
    }

    @Test func rejectsEmptyNameBadAmountAndNoThresholds() {
        var d = BudgetDraft()
        d.thresholds = []
        guard case .failure(let e) = d.validate() else { Issue.record("expected failure"); return }
        #expect(e.fields[.name] != nil && e.fields[.amount] != nil && e.fields[.thresholds] != nil)

        var zero = valid(); zero.amountText = "0"
        guard case .failure(let z) = zero.validate() else { Issue.record("expected failure"); return }
        #expect(z.fields[.amount] != nil)

        var huge = valid(); huge.amountText = "999999999"
        guard case .failure(let h) = huge.validate() else { Issue.record("expected failure"); return }
        #expect(h.fields[.amount] != nil)

        var odd = valid(); odd.thresholds = [50, 75]
        guard case .failure(let o) = odd.validate() else { Issue.record("expected failure"); return }
        #expect(o.fields[.thresholds] != nil)
    }

    @Test func projectScopeNeedsAProject() throws {
        var d = valid()
        d.scopeKind = .project
        guard case .failure(let e) = d.validate() else { Issue.record("expected failure"); return }
        #expect(e.fields[.scope] != nil)
        d.projectOrgId = "o"; d.projectId = "p"
        #expect(try d.validate().get().scope == .project(orgId: "o", projectId: "p"))
    }

    @Test func tagScopeAndEditingKeepTheId() throws {
        var d = valid()
        d.scopeKind = .tag; d.tag = .team
        let b = try d.validate().get()
        #expect(b.scope == .tag(.team))
        var edit = BudgetDraft(b)
        edit.amountText = "7000"
        let b2 = try edit.validate().get()
        #expect(b2.id == b.id && b2.amount == 7000 && b2.scope == .tag(.team))
    }
}

@MainActor
@Suite struct ModelActionTests {
    @Test func tagPickerWritesReachTheStore() async throws {
        let rig = try await makeRig(demo: true)
        await rig.model.setTag(orgId: DemoData.anthropicOrgId, target: .apiKey, targetId: "key_ci", kind: .app)
        #expect(try await rig.store.tags().contains { $0.targetId == "key_ci" && $0.kind == .app })
        #expect(KeysContent(snapshot: rig.model.snapshot, now: rig.model.now, scope: .all).rows.first { $0.name == "ci-evals" }?.tag == .app)
        await rig.model.setTag(orgId: DemoData.anthropicOrgId, target: .apiKey, targetId: "key_ci", kind: .untagged)
        #expect(!(try await rig.store.tags()).contains { $0.targetId == "key_ci" })
    }

    @Test func tagChangeMovesSpendBetweenAppAndTeam() async throws {
        let rig = try await makeRig(demo: false, factory: DemoData.factory(now: t0))
        let org = Org(id: "o", provider: .openai, displayName: "OpenAI")
        try rig.secrets.write("sk-admin-x", for: org.keychainRef)
        try await rig.store.upsertOrg(org)
        _ = await rig.model.engine.refresh(org: org)
        await rig.model.reload()
        let before = OverviewContent(snapshot: rig.model.snapshot, now: t0, scope: .all)
        #expect(before.split.first { $0.tag == .app }?.reading.amount == 0)
        await rig.model.setTag(orgId: "o", target: .project, targetId: "proj_app", kind: .app)
        let after = OverviewContent(snapshot: rig.model.snapshot, now: t0, scope: .all)
        #expect((after.split.first { $0.tag == .app }?.reading.amount ?? 0) > 0)
    }

    @Test func firstBudgetRequestsNotificationPermissionOnce() async throws {
        let rig = try await makeRig(demo: false)
        #expect(rig.notifier.requests == 0)
        var d = BudgetDraft(); d.name = "A"; d.amountText = "1000"
        #expect(await rig.model.saveBudget(d) == nil)
        #expect(rig.notifier.requests == 1)
        var d2 = BudgetDraft(); d2.name = "B"; d2.amountText = "2000"
        #expect(await rig.model.saveBudget(d2) == nil)
        #expect(rig.notifier.requests == 1)
        #expect(try await rig.store.budgets().count == 2)
        #expect(try await rig.store.setting(SettingKey.alertsEnabled) == "1")
    }

    @Test func invalidBudgetIsRejectedWithoutPermissionOrWrite() async throws {
        let rig = try await makeRig(demo: false)
        let errors = await rig.model.saveBudget(BudgetDraft())
        #expect(errors?.fields[.name] != nil)
        #expect(rig.notifier.requests == 0)
        #expect(try await rig.store.budgets().isEmpty)
    }

    @Test func editAndDeleteBudgets() async throws {
        let rig = try await makeRig(demo: true)
        var d = BudgetDraft(try #require(try await rig.store.budgets().first { $0.id == "demo-budget" }))
        d.amountText = "20000"
        #expect(await rig.model.saveBudget(d) == nil)
        #expect(try await rig.store.budgets().first { $0.id == "demo-budget" }?.amount == 20000)
        await rig.model.deleteBudget(id: "demo-budget")
        #expect(try await rig.store.budgets().map(\.id) == ["demo-budget-app"])
    }

    @Test func thresholdNotificationsFireOncePerBudgetPerThresholdPerMonth() async throws {
        var b = Built()
        b.org("a", .anthropic)
        b.daily("a", from: "2026-11-01", to: "2026-11-13", "100")
        let store = try MeterStore.inMemory()
        try await store.upsertOrg(b.orgs[0])
        try await store.upsertCostLines(b.lines)
        for c in b.coverage { try await store.saveCoverage(c) }
        let rig = try await makeRig(demo: false, store: store)
        // $1,300 used of $2,000 is 65%: only the 50% threshold has been crossed.
        var d = BudgetDraft(); d.name = "Cap"; d.amountText = "2000"
        #expect(await rig.model.saveBudget(d) == nil)
        #expect(rig.notifier.posted.map(\.title) == ["Cap reached 50%"])
        await rig.model.reload()
        await rig.model.reload()
        #expect(rig.notifier.posted.count == 1)
        // Crossing 80% later notifies once more, not again for 50%.
        try await store.upsertCostLines([CostLine(day: day("2026-11-13"), orgId: "a", amount: 400, feed: .anthropicAnalytics, model: "x")])
        await rig.model.reload()
        await rig.model.reload()
        // The $400 day is also a spike (4x the average), which notifies once too.
        #expect(rig.notifier.posted.map(\.title) == ["Cap reached 50%", "Cap reached 80%", "Spend spike on Nov 13"])
        #expect(rig.notifier.posted.filter { $0.key.hasPrefix("budget.") }.allSatisfy { $0.body.contains("does not stop spend") })
        // Fired markers live in the store settings.
        #expect(try await store.setting("alert.fired.budget.\(rig.model.snapshot.budgets[0].id).50.2026-11") == "1")
    }

    @Test func thresholdKeysIncludeTheMonthSoTheyFireAgainNextMonth() {
        var b = Built()
        b.org("a", .anthropic, through: "2026-12-02")
        b.daily("a", from: "2026-12-01", to: "2026-12-02", "600")
        b.budgets = [Budget(id: "x", name: "Cap", scope: .overall, amount: 1000)]
        let dec2 = utc("2026-12-02T12:00:00Z")
        #expect(AlertPlanner.candidates(snapshot: b.snapshot, now: dec2).map(\.key).filter { $0.hasPrefix("budget.") } == ["budget.x.50.2026-12", "budget.x.80.2026-12", "budget.x.100.2026-12"])
    }

    @Test func spikesNotifyOncePerDay() async throws {
        var b = Built()
        b.org("a", .anthropic)
        b.daily("a", from: "2026-10-20", to: "2026-11-12", "10")
        b.add("a", "2026-11-13", "100")
        let ev = AlertPlanner.candidates(snapshot: b.snapshot, now: t0).filter { $0.key.hasPrefix("spike.") }
        #expect(ev.map(\.key) == ["spike.2026-11-13"])
    }

    @Test func prepaidEntryRoundTrips() async throws {
        let rig = try await makeRig(demo: true)
        await rig.model.setPrepaid(orgId: DemoData.openAIOrgId, amount: 500, enteredAt: t0.addingTimeInterval(-86_400))
        let p = try #require(BudgetsContent(snapshot: rig.model.snapshot, now: t0).prepaid.first)
        #expect(p.enteredText?.hasPrefix("$500.00 entered") == true)
        #expect(try await rig.store.prepaidEntries().max { $0.enteredAt < $1.enteredAt }?.amount == 500)
    }

    @Test func settingsPersistToTheStore() async throws {
        let rig = try await makeRig(demo: true)
        rig.model.setMenuMetric(.mtd)
        #expect(rig.model.popover.title.text?.hasSuffix("MTD") == true)
        await rig.model.setBackgroundMinutes(30)
        await rig.model.setScope(.org(DemoData.openAIOrgId))
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await rig.store.setting(SettingKey.menuMetric) == "mtd")
        #expect(try await rig.store.setting(SettingKey.backgroundPoll) == "1800")
        #expect(try await rig.store.setting(SettingKey.scope) == "org:demo-openai")
        #expect(rig.model.popover.scopeLabel == "Acme OpenAI")
        // A fresh model over the same store restores them.
        let again = try await makeRig(demo: false, store: rig.store)
        #expect(again.model.menuMetric == .mtd && again.model.backgroundMinutes == 30 && again.model.scope == .org(DemoData.openAIOrgId))
    }

    @Test func launchAtLoginChangesOnlyOnTheToggle() async throws {
        let rig = try await makeRig(demo: false)
        #expect(rig.login.calls.isEmpty)
        rig.model.setLaunchAtLogin(true)
        #expect(rig.login.calls == [true] && rig.model.launchAtLogin)
        rig.model.setLaunchAtLogin(false)
        #expect(rig.login.calls == [true, false] && !rig.model.launchAtLogin)
    }

    @Test func windowVisibilityTracksForeground() async throws {
        let rig = try await makeRig(demo: false)
        #expect(!rig.model.isForeground)
        rig.model.surface(.popover, visible: true)
        #expect(rig.model.isForeground)
        rig.model.surface(.window, visible: true)
        rig.model.surface(.popover, visible: false)
        #expect(rig.model.isForeground)
        rig.model.surface(.window, visible: false)
        #expect(!rig.model.isForeground)
    }

    @Test func sidebarCoversEveryScreen() {
        #expect(SidebarItem.allCases.map(\.title) == ["Overview", "People", "Keys & Projects", "Models", "Budgets & Alerts", "Plan usage", "Connections", "Export"])
    }
}

@MainActor
@Suite struct ConnectionTests {
    static let marker = "sk-ant-admin01-SECRETMARKER-9f3a"

    private func draft(_ key: String = marker, provider: Provider = .anthropic, name: String = "Acme") -> ConnectionDraft {
        var d = ConnectionDraft()
        d.provider = provider; d.displayName = name; d.adminKey = key
        return d
    }

    @Test func draftValidation() {
        #expect(draft().isValid)
        // The name is optional: it defaults to the provider's name.
        #expect(draft(name: " ").isValid)
        #expect(draft(name: " ").effectiveName == "Anthropic")
        #expect(!draft("").isValid)
        // Only keys that are certainly the wrong kind block saving, each with a reason.
        #expect(!draft("sk-admin-wrong-provider").isValid)
        // User keys are accepted, with a note on what they need; the provider decides.
        #expect(draft("sk-ant-api03-regular").isValid)
        #expect(draft("sk-ant-api03-regular").warning?.contains("admin in the Console organization") == true)
        #expect(draft("sk-proj-abc", provider: .openai).isValid)
        #expect(draft("sk-proj-abc", provider: .openai).warning?.contains("Usage: Read") == true)
        #expect(!draft("sk-ant-admin01-x", provider: .openai).isValid)
        #expect(draft("sk-admin-ok", provider: .openai).isValid)
        // A new admin prefix is not locked out, and needs no warning.
        #expect(draft("sk-ant-admin02-newer").isValid)
        #expect(draft("sk-ant-admin02-newer").warning == nil)
        // Anything else unusual is allowed with a gentle warning; the provider decides.
        #expect(draft("something-unusual").isValid)
        #expect(draft("something-unusual").warning != nil)
        #expect(draft("  \(Self.marker)  ").trimmedKey == Self.marker)
    }

    @Test func savedKeyGoesToSecretsAndRunsAFirstRefresh() async throws {
        let rig = try await makeRig(demo: false)
        let result = try #require(await rig.model.addOrganization(draft()))
        #expect(result.succeeded)
        let org = try #require(try await rig.store.orgs().first)
        #expect(org.displayName == "Acme")
        #expect(try rig.secrets.read(org.keychainRef) == Self.marker)
        #expect(rig.model.snapshot.today(now: t0).state != .missing)
        #expect(result.message.hasPrefix("Connected"))
    }

    @Test func theKeyIsNeverWrittenToTheDatabaseFiles() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("meter-ui-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try MeterStore.openDefault(environment: ["METER_HOME": home.path])
        let rig = try await makeRig(demo: false, store: store)
        _ = await rig.model.addOrganization(draft())
        let marker = Data(Self.marker.utf8)
        var scanned = 0
        for sub in try FileManager.default.subpathsOfDirectory(atPath: home.path) {
            let url = home.appendingPathComponent(sub)
            if url.hasDirectoryPath { continue }
            scanned += 1
            #expect(!(try Data(contentsOf: url)).contains(marker), "key found in \(url.lastPathComponent)")
        }
        #expect(scanned >= 1)
        // The database does hold the reference, not the secret.
        let org = try #require(try await store.orgs().first)
        #expect(org.keychainRef.raw == "dev.meter.app/\(org.id)")
    }

    @Test func aRejectedKeyShowsTheErrorStateAndMessage() async throws {
        let rig = try await makeRig(demo: false, factory: { _, _ in RejectingClient(provider: .anthropic) })
        let result = try #require(await rig.model.addOrganization(draft()))
        #expect(!result.succeeded)
        #expect(result.state == .error)
        #expect(result.message.contains("rejected the key"))
        let row = try #require(ConnectionsContent(snapshot: rig.model.snapshot, now: t0).rows.first)
        #expect(row.state == .error && row.errorText != nil)
        #expect(Freshness.text(for: rig.model.snapshot.coverageSummary(now: t0).orgs[0], snapshot: rig.model.snapshot, now: t0) == "key invalid")
    }

    @Test func invalidDraftsAreNotSaved() async throws {
        let rig = try await makeRig(demo: false)
        let refused = await rig.model.addOrganization(draft("sk-admin-openai-key-on-anthropic"))
        #expect(refused?.succeeded == false)
        #expect(refused?.message.contains("OpenAI key") == true)
        #expect(try await rig.store.orgs().isEmpty)
    }

    @Test func rotateReplacesTheSecretAndRemoveDeletesIt() async throws {
        let rig = try await makeRig(demo: false)
        let added = try #require(await rig.model.addOrganization(draft()))
        let org = try #require(rig.model.snapshot.org(added.orgId))
        let bad = await rig.model.rotateKey(orgId: org.id, newKey: "sk-admin-other-provider")
        #expect(bad?.succeeded == false)
        #expect(try rig.secrets.read(org.keychainRef) == Self.marker)
        let ok = await rig.model.rotateKey(orgId: org.id, newKey: "sk-ant-admin01-NEW")
        #expect(ok?.succeeded == true)
        #expect(try rig.secrets.read(org.keychainRef) == "sk-ant-admin01-NEW")
        await rig.model.removeOrganization(id: org.id)
        #expect(try rig.secrets.read(org.keychainRef) == nil)
        #expect(try await rig.store.orgs().isEmpty)
        #expect(rig.model.snapshot.orgs.isEmpty)
    }

    @Test func removingTheScopedOrgResetsScope() async throws {
        let rig = try await makeRig(demo: true)
        await rig.model.setScope(.org(DemoData.openAIOrgId))
        await rig.model.removeOrganization(id: DemoData.openAIOrgId)
        #expect(rig.model.scope == .all)
        #expect(rig.model.snapshot.orgs.count == 1)
    }
}

@MainActor
@Suite struct ExportTests {
    @Test func csvExportHasHeaderAndRows() async throws {
        let m = try await makeRig(demo: true).model
        let csv = m.csv(from: day("2026-11-01"), to: day("2026-11-13"))
        let lines = csv.split(separator: "\n")
        #expect(lines.count > 100)
        #expect(lines[0].contains("counts_toward_total"))
        #expect(m.csvFileName(from: day("2026-11-01"), to: day("2026-11-13")) == "meter-2026-11-01-to-2026-11-13.csv")
    }

    @Test func weeklySummaryIsMarkdown() async throws {
        let m = try await makeRig(demo: true).model
        let md = m.weeklySummary()
        #expect(md.hasPrefix("# Meter weekly summary"))
        #expect(md.contains("## Budgets (alerts only, they do not stop spend)"))
        #expect(m.weeklyFileName == "meter-weekly-2026-11-13.md")
    }

    @Test func exportTextDocumentRoundTrips() throws {
        let doc = TextDocument(text: "a,b\n1,2\n")
        #expect(doc.text == "a,b\n1,2\n")
    }

    @Test func pickedDatesKeepTheirCalendarDay() {
        let d = ExportView.localDate(day("2026-11-05"))
        #expect(ExportView.utcDay(d) == day("2026-11-05"))
    }
}

@Suite struct EnvironmentGuardTests {
    /// Setu.app crashed in production when a Table cell read an @Observable from the environment during a
    /// scroll. Only these top-level scene roots may read one. Everything else gets values and closures.
    static let sceneRoots: Set<String> = ["Popover.swift", "MainWindow.swift", "SettingsView.swift"]

    @Test func onlySceneRootsReadAnObservableFromTheEnvironment() throws {
        let pattern = try Regex(#"@Environment\(\s*[A-Z][A-Za-z0-9_]*\.self\s*\)"#)
        var rootsWithEnv = Set<String>()
        for url in try SourceScan.swiftFiles(in: SourceScan.meterUIDirectory) {
            let text = try String(contentsOf: url, encoding: .utf8)
            let hits = text.matches(of: pattern)
            if !hits.isEmpty { rootsWithEnv.insert(url.lastPathComponent) }
            if !Self.sceneRoots.contains(url.lastPathComponent) {
                #expect(hits.isEmpty, "\(url.lastPathComponent) reads an Observable from the environment")
            }
        }
        #expect(rootsWithEnv == Self.sceneRoots)
    }

    @Test func noTableOrListCellDeclaresAnEnvironmentObject() throws {
        // Any file that builds a Table or List must not declare an @Environment of a type at all, except
        // the scene roots, which build the sidebar List from plain enum values.
        let env = try Regex(#"@Environment\(\s*[A-Z][A-Za-z0-9_]*\.self"#)
        let table = try Regex(#"\b(Table|List)\s*[(\{]"#)
        for url in try SourceScan.swiftFiles(in: SourceScan.meterUIDirectory) {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard !text.matches(of: table).isEmpty else { continue }
            if Self.sceneRoots.contains(url.lastPathComponent) {
                // The sidebar List's rows only use the enum value.
                #expect(text.contains("List(SidebarItem.allCases"))
                continue
            }
            #expect(text.matches(of: env).isEmpty, "\(url.lastPathComponent) mixes a Table or List with @Environment")
        }
    }

    @Test func everySceneRootIsInjectedWithTheModel() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeterApp/MeterApp.swift")
        let text = try String(contentsOf: app, encoding: .utf8)
        #expect(text.matches(of: try Regex(#"\.environment\(model\)"#)).count == 3)
        for root in ["PopoverRoot()", "MainWindowRoot()", "SettingsRoot()"] {
            #expect(text.contains("\(root).environment(model)"))
        }
    }
}
