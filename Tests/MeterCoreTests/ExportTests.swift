import Foundation
import Testing
@testable import MeterCore

private let now = utc("2026-11-13T12:00:00Z")

@Suite struct ExportTests {
    private func world() -> World {
        var w = World()
        w.addOrg("a", .anthropic, name: "Acme, \"Prod\"", through: "2026-11-13")
        w.addOrg("o", .openai, name: "Acme OpenAI", through: "2026-11-13")
        w.entities = [
            Entity(orgId: "a", kind: .apiKey, id: "k1", name: "prod, backend"),
            Entity(orgId: "a", kind: .project, id: "w1", name: "Production"),
            Entity(orgId: "a", kind: .user, id: "u1", name: "Alice", email: "alice@example.com"),
        ]
        w.tags = [Tag(orgId: "a", target: .apiKey, targetId: "k1", kind: .app)]
        return w
    }

    @Test func csvHasEveryDimensionNamesTagsAndFlags() {
        var w = world()
        w.add("a", "2026-11-12", "12.5", model: "opus", key: "k1", project: "w1", actor: "u1")
        w.add("a", "2026-11-12", "1", source: .estimated, model: "opus")
        w.add("o", "2026-11-12", "3", feed: .openaiCostsByUser, actor: "u9")
        w.add("a", "2026-11-01", "99")                                    // outside the range
        let csv = Export.csv(w.snapshot, from: day("2026-11-10"), to: day("2026-11-13"))
        let rows = csv.split(separator: "\n").map(String.init)
        #expect(rows[0] == Export.csvHeader.joined(separator: ","))
        #expect(rows.count == 4)
        let main = rows.first { $0.contains("12.5") }!
        #expect(main == "2026-11-12,anthropic,a,\"Acme, \"\"Prod\"\"\",reported,anthropicAnalytics,true,app,opus,k1,\"prod, backend\",w1,Production,u1,Alice,alice@example.com,,,12.5,USD")
        #expect(rows.contains { $0.contains(",estimated,") && $0.contains(",false,") })
        #expect(rows.contains { $0.contains("openaiCostsByUser,false") })
        #expect(csv.hasSuffix("\n"))
    }

    @Test func csvIsEmptyButHeadedWithoutLines() {
        #expect(Export.csv(World().snapshot, from: day("2026-11-01"), to: day("2026-11-30")) == Export.csvHeader.joined(separator: ",") + "\n")
    }

    @Test func weeklySummaryStatesTheBasisAndKeepsEstimatesApart() {
        var w = world()
        w.addDaily("a", from: "2026-10-30", to: "2026-11-05", "50")
        w.addDaily("a", from: "2026-11-06", to: "2026-11-12", "100", model: "opus")
        w.budgets = [Budget(id: "b", name: "Monthly", scope: .overall, amount: 2000)]
        w.claudeCode = [ClaudeCodeDay(orgId: "a", day: day("2026-11-10"), actorType: .user, actorKey: "alice@example.com", sessions: 4, estimatedCost: 12)]
        let md = Export.weeklySummary(w.snapshot, now: now)
        #expect(md.contains("Week: 2026-11-06 to 2026-11-12 (UTC). Basis: Provider-reported API cost."))
        #expect(md.contains("- This week: $700.00"))
        #expect(md.contains("- Previous week: $350.00"))
        #expect(md.contains("- Change: +100%"))
        #expect(md.contains("- Acme, \"Prod\" (Anthropic): $700.00"))
        #expect(md.contains("- opus [Acme, \"Prod\"]") == false)           // model drivers carry no org suffix
        #expect(md.contains("- opus: $700.00"))
        #expect(md.contains("## Budgets (alerts only, they do not stop spend)"))
        #expect(md.contains("- Monthly: "))
        #expect(md.contains("## Claude Code (estimated, not part of the totals above)"))
        #expect(md.contains("estimated $12.00"))
    }

    @Test func weeklySummarySaysNoDataInsteadOfZero() {
        var w = World()
        w.orgs = [Org(id: "a", provider: .anthropic, displayName: "Never synced")]
        let md = Export.weeklySummary(w.snapshot, now: now)
        #expect(md.contains("- This week: no data"))
        #expect(md.contains("- Never synced (Anthropic): no data"))
        #expect(!md.contains("$0.00"))
        #expect(md.contains("- Never synced: connected, no data yet"))
    }

    @Test func weeklySummaryFlagsPartialTotals() {
        var w = world()
        w.orgs.append(Org(id: "n", provider: .openai, displayName: "New"))
        w.addDaily("a", from: "2026-11-06", to: "2026-11-12", "10")
        #expect(Export.weeklySummary(w.snapshot, now: now).contains("$70.00 (partial, some data missing)"))
    }

    @Test func usdFormatting() {
        #expect(Export.usd(dec("1234.5")) == "$1234.50")
        #expect(Export.usd(dec("0.005")) == "$0.01")
        #expect(Export.usd(0) == "$0.00")
        #expect(Export.usd(nil) == "no data")
    }
}
