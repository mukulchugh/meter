import Foundation
import MeterCore
import Testing
@testable import MeterUI

/// A real on-disk store in a METER_HOME sandbox under the temp directory, never the real one.
private func sandbox() throws -> (dir: URL, store: MeterStore) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("meter-preview-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (dir, try MeterStore.openDefault(environment: ["METER_HOME": dir.path]))
}

private func realIsEmpty(_ store: MeterStore) async throws -> Bool {
    let s = try await store.snapshot()
    return s.orgs.isEmpty && s.lines.isEmpty && s.entities.isEmpty && s.tags.isEmpty && s.budgets.isEmpty
        && s.claudeCode.isEmpty && s.limits.isEmpty && s.prepaid.isEmpty && s.coverage.isEmpty
}

@MainActor
@Suite struct PreviewTests {
    @Test func previewOnServesTheSnapshotFromTheSampleCompany() async throws {
        let rig = try await makeRig(demo: false)
        #expect(!rig.model.isPreviewing)
        #expect(!rig.model.popover.hasOrgs)
        await rig.model.enterPreview()
        let m = rig.model
        #expect(m.isPreviewing)
        #expect(m.snapshot.orgs.count == 3)
        #expect(m.snapshot.orgs.filter { $0.provider == .anthropic }.count == 2)
        #expect(m.snapshot.orgs.filter { $0.provider == .openai }.count == 1)
        #expect(m.popover.hasOrgs)
        #expect(m.popover.today.state == .value)
        #expect(m.popover.orgs.count == 3)
    }

    @Test func sampleDataExercisesEveryState() async throws {
        let m = try await makeRig(demo: false).model
        await m.enterPreview()
        let states = Set(m.snapshot.coverageSummary(now: m.now).orgs.flatMap { $0.sources.map(\.state) })
        #expect(states.contains(.delayed))
        #expect(states.contains(.unavailableDimension))
        #expect(states.contains(.fresh))
        // Tags: App, Team and Untagged all carry spend.
        let split = OverviewContent(snapshot: m.snapshot, now: m.now, scope: .all).split
        for tag in [TagKind.app, .team, .untagged] { #expect((split.first { $0.tag == tag }?.reading.amount ?? 0) > 0) }
        // A spike, eight people with Claude Code activity, a 70% budget, an OpenAI limit and a prepaid balance.
        #expect(!OverviewContent(snapshot: m.snapshot, now: m.now, scope: .all).spikes.isEmpty)
        let people = PeopleContent(snapshot: m.snapshot, now: m.now, scope: .all)
        #expect(people.rows.filter { $0.activity != nil }.count == 8)
        let budget = try #require(m.popover.budget)
        #expect(abs(budget.fraction - 0.7) < 0.01)
        #expect(m.snapshot.limits.contains { $0.orgId == SampleData.openAIOrgId && $0.kind == .hardLimit })
        #expect(m.snapshot.prepaidStatus(orgId: SampleData.openAIOrgId, now: m.now) != nil)
    }

    @Test func realStoreAndSecretsStayUntouched() async throws {
        let (dir, store) = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rig = try await makeRig(demo: false, store: store)
        let before = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        await rig.model.enterPreview()
        // Use the sample like a person would: tag, budget, scope, refresh, dismiss.
        await rig.model.setTag(orgId: SampleData.openAIOrgId, target: .project, targetId: "proj_evals", kind: .team)
        var d = BudgetDraft(); d.name = "Sample extra"; d.amountText = "500"
        _ = await rig.model.saveBudget(d)
        await rig.model.setScope(.org(SampleData.productionOrgId))
        await rig.model.refreshAll()
        #expect(rig.model.isPreviewing)
        #expect(try await realIsEmpty(store))
        #expect(rig.notifier.requests == 0)
        for key in [SettingKey.scope, SettingKey.dismissedSuggestions, SettingKey.lastKnown(.today, .all),
                    SettingKey.lastKnown(.today, .org(SampleData.productionOrgId))] {
            #expect(try await store.setting(key) == nil)
        }
        // Only the preview flag was written, and no extra files appeared.
        #expect(try await store.setting(SettingKey.previewSampleData) == "1")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == before)
        for org in rig.model.snapshot.orgs { #expect(try rig.secrets.read(org.keychainRef) == nil) }
    }

    @Test func addingARealOrganizationExitsPreview() async throws {
        let (dir, store) = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rig = try await makeRig(demo: false, factory: DemoData.factory(now: t0), store: store)
        await rig.model.enterPreview()
        #expect(rig.model.isPreviewing)
        var draft = ConnectionDraft()
        draft.provider = .openai; draft.displayName = "Real OpenAI"; draft.adminKey = "sk-admin-real"
        let result = await rig.model.addOrganization(draft)
        #expect(result?.succeeded == true)
        let m = rig.model
        #expect(!m.isPreviewing)
        #expect(m.previewBanner == nil)
        #expect(m.snapshot.orgs.map(\.displayName) == ["Real OpenAI"])
        #expect(try await store.orgs().map(\.displayName) == ["Real OpenAI"])
        #expect(try await store.setting(SettingKey.previewSampleData) == "0")
        // The key went to the real secret store, and no sample org leaked into it.
        let org = try #require(m.snapshot.orgs.first)
        #expect(try rig.secrets.read(org.keychainRef) == "sk-admin-real")
        #expect(m.hasRealOrgs)
        // With a real org, preview is no longer offered and entering it does nothing.
        #expect(!m.canPreview)
        await m.enterPreview()
        #expect(!m.isPreviewing)
    }

    @Test func invalidDraftDoesNotExitPreview() async throws {
        let rig = try await makeRig(demo: false)
        await rig.model.enterPreview()
        let refused = await rig.model.addOrganization(ConnectionDraft())
        #expect(refused?.succeeded == false)
        #expect(refused?.message.isEmpty == false)
        #expect(rig.model.isPreviewing)
    }

    @Test func bannerShowsOnlyWhilePreviewing() async throws {
        let rig = try await makeRig(demo: false)
        #expect(rig.model.previewBanner == nil)
        await rig.model.enterPreview()
        let banner = try #require(rig.model.previewBanner)
        #expect(banner.text == "Sample data. Not your spend.")
        #expect(banner.exitTitle == "Exit preview")
        await rig.model.exitPreview()
        #expect(rig.model.previewBanner == nil)
        #expect(rig.model.snapshot.orgs.isEmpty)
        #expect(!rig.model.popover.hasOrgs)
    }

    @Test func previewChoiceSurvivesRelaunchAndExitSurvivesToo() async throws {
        let (dir, store) = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try await makeRig(demo: false, store: store)
        await first.model.enterPreview()
        // "Relaunch": a new model over the same real store.
        let second = try await makeRig(demo: false, store: store)
        #expect(second.model.isPreviewing)
        #expect(second.model.snapshot.orgs.count == 3)
        #expect(second.model.previewBanner != nil)
        await second.model.exitPreview()
        let third = try await makeRig(demo: false, store: store)
        #expect(!third.model.isPreviewing)
        #expect(third.model.snapshot.orgs.isEmpty)
        #expect(try await realIsEmpty(store))
    }

    @Test func savedPreviewIsDroppedWhenARealOrgExists() async throws {
        let (dir, store) = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.upsertOrg(Org(id: "real", provider: .anthropic, displayName: "Real"))
        try await store.setSetting(SettingKey.previewSampleData, "1")
        let rig = try await makeRig(demo: false, store: store)
        #expect(!rig.model.isPreviewing)
        #expect(rig.model.snapshot.orgs.map(\.id) == ["real"])
        #expect(try await store.setting(SettingKey.previewSampleData) == "0")
    }

    @Test func emptyStateRequestOpensConnectionsWithTheAddForm() async throws {
        let m = try await makeRig(demo: false).model
        m.beginAddOrganization()
        #expect(m.selection == .connections)
        #expect(m.addOrganizationRequested)
    }
}
