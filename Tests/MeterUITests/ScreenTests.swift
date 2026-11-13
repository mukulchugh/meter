import Foundation
import MeterCore
import Testing
@testable import MeterUI

@MainActor
@Suite struct DemoScreenTests {
    @Test func demoModelLoadsEveryScreenWithoutKeysOrNetwork() async throws {
        let rig = try await makeRig(demo: true)
        let m = rig.model
        #expect(m.isDemo)
        #expect(m.snapshot.orgs.count == 2)
        #expect(m.popover.today.state == .value)
        #expect(m.popover.orgs.count == 2)
        #expect(m.popover.title.text?.hasSuffix("today") == true)
    }

    @Test func overviewComparesMonthsAndShowsBothProjections() async throws {
        let m = try await makeRig(demo: true).model
        let c = OverviewContent(snapshot: m.snapshot, now: m.now, scope: .all)
        #expect(c.comparison.thisMonth.amount != nil)
        #expect(c.comparison.lastMonth.state == .value)
        #expect(c.comparison.changePercent != nil)
        #expect(c.projection.projection.projectedByElapsedFraction != nil)
        #expect(c.projection.projection.projectedByRunRate != nil)
        #expect(c.projection.runRateText.contains("run rate"))
        #expect(c.projection.elapsedText.contains("elapsed"))
        #expect(c.projection.budgetNote?.contains("alert only, does not stop spend") == true)
        #expect(c.drivers.count == 4)
        #expect(c.daily.count == 13)
        #expect(c.cumulative.count == 13)
        #expect(c.chips.count == 2)
        #expect(c.split.map(\.tag) == [.app, .team, .untagged])
    }

    @Test func cumulativeLineNeverDecreasesAndMatchesTheMonthTotal() async throws {
        let m = try await makeRig(demo: true).model
        let c = OverviewContent(snapshot: m.snapshot, now: m.now, scope: .all)
        let values = c.cumulative.compactMap(\.value)
        #expect(values == values.sorted())
        let mtd = try #require(c.comparison.thisMonth.amount)
        #expect(abs(values.last! - Fmt.chartValue(mtd)) < 0.01)
    }

    @Test func topDriversAreFiveAtMost() async throws {
        let m = try await makeRig(demo: true).model
        for d in DriverDimension.allCases {
            let c = OverviewContent(snapshot: m.snapshot, now: m.now, scope: .all, driverDimension: d)
            #expect(c.drivers.count <= 5)
        }
    }

    @Test func spikeIsDetected() async throws {
        let m = try await makeRig(demo: true).model
        let c = OverviewContent(snapshot: m.snapshot, now: m.now, scope: .all)
        #expect(c.spikes.contains { $0.id == "2026-11-10" })
    }

    @Test func peopleMergeByEmailAndKeepEstimatesApart() async throws {
        let m = try await makeRig(demo: true).model
        let c = PeopleContent(snapshot: m.snapshot, now: m.now, scope: .all)
        let ana = try #require(c.rows.first { $0.email == "ana@acme.dev" })
        #expect(ana.anthropic != nil && ana.openai != nil)
        #expect(ana.total == (ana.anthropic ?? 0) + (ana.openai ?? 0))
        #expect(ana.activity?.sessions ?? 0 > 0)
        #expect(ana.estimatedCostText != ana.totalText)
        // A person with only Claude Code activity has no reported total, and says so.
        let dee = try #require(c.rows.first { $0.email == "dee@acme.dev" })
        #expect(dee.total == nil && dee.totalText == "None")
        #expect(dee.activity != nil)
        #expect(c.unmatched.contains { $0.name == "user_ghost" })
        #expect(c.apiActors.contains { $0.id == "ci-evals" })
        #expect(PeopleContent.estimateColumnTitle == "Claude Code cost (estimate)")
    }

    @Test func keysTableFlagsUnusedKeysAndKeepsAnthropicTodayEmpty() async throws {
        let m = try await makeRig(demo: true).model
        let c = KeysContent(snapshot: m.snapshot, now: m.now, scope: .all)
        let old = try #require(c.rows.first { $0.name == "legacy-batch" })
        #expect(old.isUnused)
        #expect(old.flagText == "Unused 30 days")
        let prod = try #require(c.rows.first { $0.name == "prod-api" })
        #expect(prod.today == nil && prod.todayText == "No data")
        #expect(prod.tag == .app)
        let oaProd = try #require(c.rows.first { $0.name == "prod-key" })
        #expect(oaProd.today != nil)
        #expect(c.rows.contains { $0.kindText == "Workspace" } && c.rows.contains { $0.kindText == "Project" })
        let ana = try #require(c.rows.first { $0.name == "ana-dev" })
        #expect(ana.owner == "Ana Silva")
    }

    @Test func runawayKeyIsFlagged() {
        var b = Built()
        b.org("a", .anthropic)
        b.entities = [Entity(orgId: "a", kind: .apiKey, id: "k", name: "hot")]
        for d in UTCDay.range(from: day("2026-10-25"), through: day("2026-11-11")) { b.add("a", d.string, "10", key: "k") }
        b.add("a", "2026-11-12", "100", key: "k")
        b.add("a", "2026-11-13", "100", key: "k")
        let c = KeysContent(snapshot: b.snapshot, now: t0, scope: .all)
        #expect(c.rows.first?.isRunaway == true)
        #expect(c.rows.first?.flagText == "Runaway")
    }

    @Test func suggestionsAreProposalsUntilAccepted() async throws {
        let rig = try await makeRig(demo: true)
        let c = KeysContent(snapshot: rig.model.snapshot, now: rig.model.now, scope: .all)
        let s = try #require(c.suggestions.first { $0.name == "ben-local" })
        #expect(s.suggested == .team)
        // Showing a suggestion changes nothing.
        let before = try await rig.store.tags()
        #expect(!before.contains { $0.targetId == s.suggestion.targetId })
        await rig.model.dismiss(s.suggestion)
        let after = KeysContent(snapshot: rig.model.snapshot, now: rig.model.now, scope: .all, dismissed: rig.model.dismissedSuggestions)
        #expect(!after.suggestions.contains { $0.name == "ben-local" })
        #expect(!(try await rig.store.tags()).contains { $0.targetId == s.suggestion.targetId })
        await rig.model.accept(try #require(c.suggestions.first { $0.name == "dev-cy" }).suggestion)
        #expect((try await rig.store.tags()).contains { $0.targetId == "key_oa_lab" && $0.kind == .team })
    }

    @Test func modelsSharesAddUpAndTokensAreExplicitlyUnavailable() async throws {
        let m = try await makeRig(demo: true).model
        let c = ModelsContent(snapshot: m.snapshot, now: m.now, scope: .all)
        #expect(c.rows.count >= 4)
        #expect(abs(c.rows.reduce(0) { $0 + $1.share } - 1) < 0.0001)
        #expect(c.rows == c.rows.sorted { $0.amount > $1.amount })
        #expect(ModelsContent.tokensNote.contains("not available"))
    }

    @Test func budgetsScreenShowsLimitsReadOnlyAndPrepaidAsEstimate() async throws {
        let m = try await makeRig(demo: true).model
        let c = BudgetsContent(snapshot: m.snapshot, now: m.now)
        #expect(c.budgets.count == 2)
        #expect(c.budgets.allSatisfy { !$0.thresholdsText.isEmpty })
        #expect(c.limits.count == 3)
        #expect(c.limits.contains { $0.kindText == "Hard limit, enforced by OpenAI" })
        let p = try #require(c.prepaid.first)
        #expect(p.remainingText != nil && p.daysLeftText != nil)
        #expect(PrepaidRow.label == "estimate from your entered balance")
        #expect(c.projectChoices.count == 4)
    }

    @Test func connectionsShowHealthAndDimensions() async throws {
        let m = try await makeRig(demo: true).model
        let c = ConnectionsContent(snapshot: m.snapshot, now: m.now)
        #expect(c.rows.count == 2)
        for r in c.rows {
            #expect(!r.dimensions.isEmpty)
            #expect(r.lastReportText.hasPrefix("Last report"))
        }
        #expect(ConnectionHelp.steps(for: .anthropic).contains("platform.claude.com/settings/admin-keys"))
        #expect(ConnectionHelp.steps(for: .openai).contains("platform.openai.com/settings/organization/admin-keys"))
        #expect(ConnectionHelp.organizationNote.contains("organization account"))
    }
}
