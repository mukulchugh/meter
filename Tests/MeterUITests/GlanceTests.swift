import Foundation
import MeterCore
import Testing
@testable import MeterUI

@Suite struct MenuBarTitleTests {
    private func world() -> Built {
        var b = Built()
        b.org("a", .anthropic, name: "Console")
        b.daily("a", from: "2026-11-01", to: "2026-11-13", "412")
        return b
    }

    @Test func todayIsTheDefault() {
        let t = MenuBarTitle.make(metric: .today, snapshot: world().snapshot, now: t0, scope: .all, lastKnown: nil)
        #expect(t.text == "$412 today")
        #expect(!t.showsAttention)
    }

    @Test func monthToDateUsesMTD() {
        let t = MenuBarTitle.make(metric: .mtd, snapshot: world().snapshot, now: t0, scope: .all, lastKnown: nil)
        #expect(t.text == "$5,356 MTD")
    }

    @Test func iconOnlyHasNoText() {
        let t = MenuBarTitle.make(metric: .iconOnly, snapshot: world().snapshot, now: t0, scope: .all, lastKnown: nil)
        #expect(t.text == nil)
        #expect(!t.showsAttention)
    }

    @Test func missingDataShowsAttentionNeverZero() {
        var b = Built()
        b.org("a", .anthropic, through: "2026-11-05")
        let t = MenuBarTitle.make(metric: .today, snapshot: b.snapshot, now: t0, scope: .all, lastKnown: nil)
        #expect(t.text == nil)
        #expect(t.showsAttention)
        #expect(!(t.text ?? "").contains("$0"))
    }

    @Test func missingDataKeepsTheLastKnownValue() {
        var b = Built()
        b.org("a", .anthropic, through: "2026-11-05")
        let t = MenuBarTitle.make(metric: .today, snapshot: b.snapshot, now: t0, scope: .all, lastKnown: dec("388"))
        #expect(t.text == "$388 today")
        #expect(t.showsAttention)
        #expect(t.accessibilityLabel.contains("last known"))
    }

    @Test func aFailingFeedKeepsTheValueAndAddsAttention() {
        var b = world()
        b.coverage = [Coverage(orgId: "a", source: .anthropicAnalytics, lastSuccess: utc("2026-11-13T09:00:00Z"),
                               coveredFrom: day("2026-01-01"), coveredThrough: day("2026-11-13"),
                               lastError: "boom", errorKind: "server")]
        let t = MenuBarTitle.make(metric: .today, snapshot: b.snapshot, now: t0, scope: .all, lastKnown: nil)
        #expect(t.text == "$412 today")
        #expect(t.showsAttention)
    }

    @Test func noOrganizationsShowsOnlyTheGlyph() {
        let t = MenuBarTitle.make(metric: .today, snapshot: MeterSnapshot(), now: t0, scope: .all, lastKnown: nil)
        #expect(t.text == nil)
        #expect(t.showsAttention)
    }

    @Test func orgScopeNarrowsTheNumber() {
        var b = world()
        b.org("o", .openai, name: "OpenAI")
        b.daily("o", from: "2026-11-01", to: "2026-11-13", "100")
        let all = MenuBarTitle.make(metric: .today, snapshot: b.snapshot, now: t0, scope: .all, lastKnown: nil)
        let one = MenuBarTitle.make(metric: .today, snapshot: b.snapshot, now: t0, scope: .org("o"), lastKnown: nil)
        #expect(all.text == "$512 today")
        #expect(one.text == "$100 today")
    }
}

@Suite struct PopoverTests {
    private func world() -> Built {
        var b = Built()
        b.org("small", .openai, name: "OpenAI Lab", success: "2026-11-13T11:30:00Z")
        b.org("big", .anthropic, name: "Console", success: "2026-11-13T09:00:00Z", watermark: "2026-11-13T09:00:00Z")
        b.org("none", .anthropic, name: "Zeta", through: "2026-11-01")
        b.daily("big", from: "2026-11-01", to: "2026-11-13", "300")
        b.daily("small", from: "2026-11-01", to: "2026-11-13", "20")
        b.budgets = [Budget(id: "b", name: "Monthly", scope: .overall, amount: 10_000)]
        return b
    }

    @Test func rowsAreLargestFirstWithMissingLast() {
        let c = PopoverContent(snapshot: world().snapshot, now: t0, scope: .all)
        #expect(c.orgs.map(\.name) == ["Console", "OpenAI Lab", "Zeta"])
        #expect(c.orgs[0].amountText == "$300.00")
        #expect(c.orgs[2].amountText == "No data")
    }

    @Test func freshnessTextIsPlain() {
        let c = PopoverContent(snapshot: world().snapshot, now: t0, scope: .all)
        #expect(c.orgs[0].freshness == "reported 3h ago")
        #expect(c.orgs[1].freshness == "reported 30 min ago")
    }

    @Test func delayedAndInvalidKeyText() {
        var b = Built()
        b.org("late", .anthropic, name: "Late", success: "2026-11-13T11:30:00Z", watermark: "2026-11-13T04:00:00Z")
        b.org("bad", .openai, name: "Bad", error: "rejected", errorKind: "auth")
        b.org("new", .openai, name: "New")
        b.coverage.removeAll { $0.orgId == "new" }
        let c = PopoverContent(snapshot: b.snapshot, now: t0, scope: .all)
        let by = Dictionary(uniqueKeysWithValues: c.orgs.map { ($0.name, $0.freshness) })
        #expect(by["Late"]?.hasPrefix("delayed") == true)
        #expect(by["Bad"]?.hasPrefix("key invalid") == true)
        #expect(by["New"] == "waiting for first report")
    }

    @Test func headerAndSplit() {
        var b = world()
        b.tags = [Tag(orgId: "big", target: .project, targetId: "p", kind: .app)]
        b.add("big", "2026-11-13", "50", project: "p")
        let c = PopoverContent(snapshot: b.snapshot, now: t0, scope: .all)
        #expect(c.scopeLabel == "All organizations")
        #expect(c.reportedText.hasPrefix("Reported through"))
        #expect(c.split.map(\.tag) == [.app, .team, .untagged])
        #expect(c.split[0].text.hasPrefix("$50.00"))
        let one = PopoverContent(snapshot: b.snapshot, now: t0, scope: .org("small"))
        #expect(one.scopeLabel == "OpenAI Lab")
    }

    @Test func weekChartHasSevenDaysOldestFirst() {
        let c = PopoverContent(snapshot: world().snapshot, now: t0, scope: .all)
        #expect(c.week.count == 7)
        #expect(c.week.first?.day == day("2026-11-07"))
        #expect(c.week.last?.label == "Fri")
        #expect(c.week.allSatisfy { $0.value != nil })
    }

    @Test func budgetBarSaysItDoesNotStopSpend() {
        let c = PopoverContent(snapshot: world().snapshot, now: t0, scope: .all)
        let bar = try! #require(c.budget)
        #expect(bar.usedText == "$4,160.00")
        #expect(bar.targetText == "$10,000.00")
        #expect(bar.percentText == "42%")
        #expect(BudgetBar.note == "alert only, does not stop spend")
    }

    @Test func emptyAppShowsAnInvitationNotZero() {
        let c = PopoverContent(snapshot: MeterSnapshot(), now: t0, scope: .all)
        #expect(c.today.state == .missing)
        #expect(c.todayText == "No data")
        #expect(c.reportedText == "Add an organization to start")
        #expect(c.orgs.isEmpty)
    }
}
