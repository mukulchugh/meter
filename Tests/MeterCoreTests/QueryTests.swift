import Foundation
import Testing
@testable import MeterCore

private let now = utc("2026-11-13T12:00:00Z")

private func world() -> World {
    var w = World()
    w.addOrg("a", .anthropic, name: "Acme Anthropic", through: "2026-11-13")
    w.addOrg("o", .openai, name: "Acme OpenAI", through: "2026-11-13")
    return w
}

@Suite struct TotalsTests {
    @Test func todayAndMonthToDateOverallPerOrgPerProviderPerTag() {
        var w = world()
        w.add("a", "2026-11-13", "40", key: "kapp")
        w.add("a", "2026-11-13", "10", key: "kdev")
        w.add("a", "2026-11-13", "5")
        w.add("o", "2026-11-13", "20", project: "pteam")
        w.add("o", "2026-11-02", "100", project: "pteam")
        w.add("a", "2026-10-31", "999")
        w.tags = [Tag(orgId: "a", target: .apiKey, targetId: "kapp", kind: .app),
                  Tag(orgId: "a", target: .apiKey, targetId: "kdev", kind: .team),
                  Tag(orgId: "o", target: .project, targetId: "pteam", kind: .team)]
        let s = w.snapshot

        #expect(s.today(now: now).amount == 75)
        #expect(s.today(now: now).state == .value)
        #expect(s.monthToDate(now: now).amount == 175)

        let byOrg = s.totalsByOrg(from: day("2026-11-01"), to: day("2026-11-13"))
        #expect(byOrg.map(\.reading.amount) == [55, 120])
        #expect(byOrg.map(\.org.id) == ["a", "o"])

        let byProvider = s.totalsByProvider(from: day("2026-11-13"), to: day("2026-11-13"))
        #expect(byProvider.map(\.provider) == [.anthropic, .openai])
        #expect(byProvider.map(\.reading.amount) == [55, 20])

        let byTag = s.totalsByTag(from: day("2026-11-13"), to: day("2026-11-13"))
        #expect(byTag.map(\.tag) == [.app, .team, .untagged])
        #expect(byTag.map(\.reading.amount) == [40, 30, 5])
        // The three tags partition the total: nothing is dropped or counted twice.
        #expect(byTag.compactMap(\.reading.amount).reduce(0, +) == s.today(now: now).amount)

        #expect(s.previousMonth(now: now).amount == 999)
        #expect(s.total(from: day("2026-11-01"), to: day("2026-11-13"), filter: CostFilter(provider: .openai, tag: .team)).amount == 120)
    }

    @Test func keyTagWinsOverProjectTag() {
        var w = world()
        w.add("a", "2026-11-13", "10", key: "k1", project: "p1")
        w.add("a", "2026-11-13", "20", project: "p1")
        w.tags = [Tag(orgId: "a", target: .apiKey, targetId: "k1", kind: .team), Tag(orgId: "a", target: .project, targetId: "p1", kind: .app)]
        let by = w.snapshot.totalsByTag(from: day("2026-11-13"), to: day("2026-11-13"))
        #expect(by.map(\.reading.amount) == [20, 10, 0])
    }

    @Test func missingDataIsNilNeverZero() {
        var w = World()
        w.orgs = [Org(id: "a", provider: .anthropic, displayName: "A")]   // connected, nothing fetched
        let r = w.snapshot.today(now: now)
        #expect(r.amount == nil && r.state == .missing && r.missingOrgIds == ["a"])
        #expect(World().snapshot.today(now: now).amount == nil)
        // A failed org with no successful fetch is still missing, not zero.
        w.coverage = [Coverage(orgId: "a", source: .anthropicAnalytics, lastError: "x")]
        #expect(w.snapshot.monthToDate(now: now).state == .missing)
    }

    @Test func coveredDayWithNoSpendIsNoActivityAndOnlyThenZero() {
        let w = world()
        let r = w.snapshot.today(now: now)
        #expect(r.amount == 0 && r.state == .noActivity)
    }

    @Test func oneOrgMissingMakesTheTotalPartial() {
        var w = world()
        w.orgs.append(Org(id: "b", provider: .openai, displayName: "Never synced"))
        w.add("a", "2026-11-13", "10")
        let r = w.snapshot.today(now: now)
        #expect(r.state == .partial && r.amount == 10 && r.missingOrgIds == ["b"])
    }

    @Test func staleCoverageWithinRangeKeepsLastKnownValue() {
        var w = world()
        w.coverage = w.coverage.map { var c = $0; c.coveredThrough = day("2026-11-12"); return c }
        w.add("a", "2026-11-12", "30")
        let r = w.snapshot.monthToDate(now: now)
        #expect(r.state == .partial && r.amount == 30)
        // Yesterday alone is fully covered.
        #expect(w.snapshot.total(from: day("2026-11-12"), to: day("2026-11-12")).state == .value)
        // Today is not covered by anyone.
        #expect(w.snapshot.today(now: now).state == .missing)
    }

    @Test func neverSumsEstimatedWithReported() {
        var w = world()
        w.add("a", "2026-11-13", "100")
        w.add("a", "2026-11-13", "55", source: .estimated)
        w.claudeCode = [ClaudeCodeDay(orgId: "a", day: day("2026-11-13"), actorType: .user, actorKey: "x@y.z", estimatedCost: 77)]
        let s = w.snapshot
        #expect(s.today(now: now).amount == 100)
        #expect(s.monthToDate(now: now).amount == 100)
        #expect(s.totalsByOrg(from: day("2026-11-13"), to: day("2026-11-13"))[0].reading.amount == 100)
        #expect(s.totalsByTag(from: day("2026-11-13"), to: day("2026-11-13")).compactMap(\.reading.amount).reduce(0, +) == 100)
        #expect(s.dailySeries(days: 7, now: now).last?.reading.amount == 100)
        #expect(s.topDrivers(.model, from: day("2026-11-13"), to: day("2026-11-13")).map(\.amount) == [100])
        #expect(s.estimatedTotal(from: day("2026-11-13"), to: day("2026-11-13")) == 55)
        // Claude Code estimates live in their own query and never touch org spend.
        #expect(s.claudeCodeActivity(from: day("2026-11-13"), to: day("2026-11-13"))[0].estimatedCost == 77)
    }

    @Test func supplementalPerUserFeedIsNotCountedTwice() {
        var w = world()
        w.add("o", "2026-11-13", "50", project: "p")
        w.add("o", "2026-11-13", "50", feed: .openaiCostsByUser, actor: "user-a")
        #expect(w.snapshot.today(now: now).amount == 50)
    }

    @Test func nonUSDLinesAreIgnoredRatherThanSummed() {
        var w = world()
        w.add("a", "2026-11-13", "10")
        w.lines.append(CostLine(day: day("2026-11-13"), orgId: "a", amount: 999, currency: "EUR", feed: .anthropicAnalytics, model: "x"))
        #expect(w.snapshot.today(now: now).amount == 10)
    }

    @Test func dailySeriesSevenAndThirtyDays() {
        var w = world()
        w.addDaily("a", from: "2026-10-15", to: "2026-11-13", "10")
        let s = w.snapshot
        let seven = s.weekSeries(now: now)
        #expect(seven.count == 7 && seven.first?.day == day("2026-11-07") && seven.last?.day == day("2026-11-13"))
        #expect(seven.allSatisfy { $0.reading.amount == 10 })
        let thirty = s.monthSeries(now: now)
        #expect(thirty.count == 30 && thirty.first?.day == day("2026-10-15"))
        #expect(thirty.compactMap(\.reading.amount).reduce(0, +) == 300)
    }

    @Test func seriesMarksUncoveredDaysMissingNotZero() {
        var w = world()
        w.coverage = w.coverage.map { var c = $0; c.coveredThrough = day("2026-11-11"); return c }
        w.addDaily("a", from: "2026-11-07", to: "2026-11-11", "10")
        let s = w.snapshot.weekSeries(now: now)
        #expect(s[4].reading.state == .value)
        #expect(s[5].reading.amount == nil && s[5].reading.state == .missing)
        #expect(s[6].reading.amount == nil)
    }

    @Test func seriesShowsQuietCoveredDaysAsNoActivity() {
        var w = world()
        w.add("a", "2026-11-13", "10")
        let s = w.snapshot.weekSeries(now: now)
        #expect(s[0].reading.state == .noActivity && s[0].reading.amount == 0)
    }
}

@Suite struct DriverTests {
    @Test func topDriversByModelKeyProject() {
        var w = world()
        w.entities = [Entity(orgId: "a", kind: .apiKey, id: "k1", name: "prod-backend"),
                      Entity(orgId: "a", kind: .project, id: "w1", name: "Production")]
        w.add("a", "2026-11-12", "60", model: "opus", key: "k1", project: "w1")
        w.add("a", "2026-11-12", "30", model: "sonnet", key: "k1", project: "w1")
        w.add("a", "2026-11-12", "10", model: "opus")                          // legacy style: no key, default workspace
        w.add("o", "2026-11-12", "20", model: nil, key: "k9", project: "p9")
        let s = w.snapshot
        let from = day("2026-11-12"), to = day("2026-11-12")

        let models = s.topDrivers(.model, limit: 5, from: from, to: to)
        #expect(models.map(\.name) == ["opus", "Unknown model", "sonnet"].sorted { a, b in
            let order = ["opus": 70, "Unknown model": 20, "sonnet": 30]; return order[a]! > order[b]!
        })
        #expect(models[0].amount == 70 && models[0].share == 70.0 / 120.0)
        #expect(models.first { $0.name == "Unknown model" }?.isUnattributed == true)

        let keys = s.topDrivers(.apiKey, limit: 2, from: from, to: to)
        #expect(keys.count == 2)
        #expect(keys[0].name == "prod-backend" && keys[0].amount == 90 && keys[0].orgId == "a")
        // Unresolved key ids fall back to the id; missing keys are flagged, not dropped.
        let all = s.topDrivers(.apiKey, limit: 10, from: from, to: to)
        #expect(all.first { $0.id == "k9" }?.name == "k9")
        #expect(all.first { $0.id == nil }?.isUnattributed == true)

        let projects = s.topDrivers(.project, limit: 10, from: from, to: to)
        #expect(projects.first { $0.id == "w1" }?.name == "Production")
        #expect(projects.first { $0.id == nil && $0.orgId == "a" }?.name == "Default workspace")
        #expect(projects.first { $0.id == nil && $0.orgId == "a" }?.isUnattributed == false)
    }

    @Test func limitCapsTheList() {
        var w = world()
        for i in 0..<10 { w.add("a", "2026-11-12", "\(i + 1)", model: "m\(i)") }
        let d = w.snapshot.topDrivers(.model, limit: 3, from: day("2026-11-12"), to: day("2026-11-12"))
        #expect(d.map(\.name) == ["m9", "m8", "m7"])
    }
}

@Suite struct PeopleTests {
    @Test func mergesAcrossProvidersByCaseInsensitiveEmailAndListsUnmatched() {
        var w = world()
        w.entities = [
            Entity(orgId: "a", kind: .user, id: "user_1", name: "Alice Doe", email: "Alice@Example.com"),
            Entity(orgId: "o", kind: .user, id: "user-a", name: "alice", email: "alice@EXAMPLE.com"),
            Entity(orgId: "a", kind: .user, id: "user_2", name: "No Email", email: nil),
            Entity(orgId: "a", kind: .apiKey, id: "apikey_9", name: "ci"),
        ]
        w.add("a", "2026-11-12", "30", actor: "user_1")
        w.add("o", "2026-11-12", "20", feed: .openaiCostsByUser, actor: "user-a")
        w.add("o", "2026-11-12", "5", feed: .openaiCostsByUser, actor: "ghost")
        w.add("a", "2026-11-12", "4", actor: "apikey_9")
        w.add("a", "2026-11-12", "3", actor: "user_2")
        w.add("a", "2026-11-12", "100")                                          // no actor: not person spend
        let r = w.snapshot.people(from: day("2026-11-12"), to: day("2026-11-12"))

        #expect(r.people.count == 1)
        let alice = r.people[0]
        #expect(alice.email == "alice@example.com" && alice.total == 50)
        #expect(alice.byProvider == [.anthropic: 30, .openai: 20])
        #expect(alice.byOrg == ["a": 30, "o": 20])
        #expect(alice.displayName == "Alice Doe")

        #expect(r.unmatched.map(\.actorId) == ["ghost", "apikey_9", "user_2"])
        #expect(r.unmatched.map(\.reason) == [.noUserRecord, .nonUserActor, .noEmail])
        #expect(r.unmatched.map(\.amount) == [5, 4, 3])

        let drivers = w.snapshot.topDrivers(.person, limit: 5, from: day("2026-11-12"), to: day("2026-11-12"))
        #expect(drivers.map(\.amount) == [50, 12])
        #expect(drivers[1].isUnattributed)
    }

    @Test func emailActorNeedsNoEntity() {
        var w = world()
        w.add("a", "2026-11-12", "9", actor: "Bob@Example.com")
        let r = w.snapshot.people(from: day("2026-11-12"), to: day("2026-11-12"))
        #expect(r.people.map(\.email) == ["bob@example.com"] && r.unmatched.isEmpty)
    }

    @Test func respectsFilterAndRange() {
        var w = world()
        w.entities = [Entity(orgId: "a", kind: .user, id: "u", name: "U", email: "u@x.io")]
        w.add("a", "2026-11-10", "5", actor: "u")
        w.add("a", "2026-11-12", "7", actor: "u")
        let s = w.snapshot
        #expect(s.people(from: day("2026-11-11"), to: day("2026-11-13")).people[0].total == 7)
        #expect(s.people(from: day("2026-11-01"), to: day("2026-11-13"), filter: CostFilter(provider: .openai)).people.isEmpty)
    }
}

@Suite struct ProjectionTests {
    private func flat() -> World {
        var w = world()
        w.addDaily("a", from: "2026-11-01", to: "2026-11-12", "100")
        w.add("a", "2026-11-13", "70")
        return w
    }

    @Test func runRateAndElapsedFractionAreBothReported() throws {
        let p = flat().snapshot.projection(now: now)
        #expect(p.monthToDate.amount == 1270)
        #expect(p.runRateDaily == 100 && p.runRateDays == 7)
        // 1200 through yesterday + 100 * 18 days left including today.
        #expect(p.projectedByRunRate == 3000)
        // 12.5 of 30 days elapsed.
        #expect(abs(p.elapsedFraction - 12.5 / 30) < 1e-9)
        let byFraction = try #require(p.projectedByElapsedFraction)
        #expect(abs(NSDecimalNumber(decimal: byFraction).doubleValue - 3048) < 0.01)
        #expect(p.monthEnd == day("2026-11-30"))
    }

    @Test func tooFewCoveredDaysGivesNoRunRate() {
        var w = world()
        // Coverage ends 2026-11-07: of the seven days before today only 11-06 and 11-07 are covered.
        w.coverage = w.coverage.map { var c = $0; c.coveredThrough = day("2026-11-07"); return c }
        w.addDaily("a", from: "2026-11-01", to: "2026-11-07", "100")
        let p = w.snapshot.projection(now: now)
        #expect(p.runRateDays == 2 && p.runRateDaily == nil && p.projectedByRunRate == nil)
        // The elapsed-fraction figure still shows, flagged by the partial reading.
        #expect(p.monthToDate.state == .partial)
    }

    @Test func noCoverageMeansNoProjection() {
        var w = World()
        w.orgs = [Org(id: "a", provider: .anthropic, displayName: "A")]
        let p = w.snapshot.projection(now: now)
        #expect(p.runRateDaily == nil && p.projectedByRunRate == nil && p.projectedByElapsedFraction == nil)
        #expect(p.monthToDate.state == .missing)
    }

    @Test func firstOfTheMonthUsesRateOnly() {
        var w = world()
        w.addDaily("a", from: "2026-10-25", to: "2026-10-31", "10")
        let p = w.snapshot.projection(now: utc("2026-11-01T06:00:00Z"))
        #expect(p.runRateDaily == 10 && p.projectedByRunRate == 300)
        #expect(p.monthToDate.amount == 0)
    }
}

@Suite struct BudgetTests {
    private func status(_ amount: Decimal, scope: BudgetScope = .overall, base: World? = nil) -> BudgetStatus {
        var w = base ?? {
            var w = world()
            w.addDaily("a", from: "2026-11-01", to: "2026-11-12", "100")
            w.add("a", "2026-11-13", "70")
            return w
        }()
        w.budgets = [Budget(id: "b", name: "B", scope: scope, amount: amount)]
        return w.snapshot.budgetStatus(w.budgets[0], now: now)
    }

    @Test func percentThresholdsAndProjectedCrossingDate() {
        let s = status(2000)
        #expect(s.tracking.used == 1270)
        #expect(abs((s.tracking.percent ?? 0) - 63.5) < 1e-9)
        #expect(s.thresholdsCrossed == [50])
        #expect(s.nextThreshold == 80)
        // 80%: 1600 needs 400 more after yesterday's 1200 at 100/day -> 4 days -> 2026-11-16.
        #expect(s.tracking.projectedCrossings[80] == day("2026-11-16"))
        // 100%: 800 more -> 8 days -> 2026-11-20.
        #expect(s.projectedCrossing == day("2026-11-20"))
        #expect(s.tracking.projectedCrossings[50] == nil)
        #expect(!s.tracking.exceeded)
        #expect(s.consequence == "Alert target: does not stop requests")
    }

    @Test func thresholdBoundariesAreExact() {
        // 1270 against 2540 is exactly 50%.
        #expect(status(2540).thresholdsCrossed == [50])
        // Just under 50%.
        #expect(status(dec("2540.01")).thresholdsCrossed == [])
        // Exactly 100% counts as reached.
        let hit = status(1270)
        #expect(hit.thresholdsCrossed == [50, 80, 100] && hit.tracking.exceeded && hit.projectedCrossing == nil)
        #expect(status(1000).thresholdsCrossed == [50, 80, 100])
        #expect(status(1000).nextThreshold == nil)
    }

    @Test func crossingBeyondMonthEndIsNotProjected() {
        #expect(status(100_000).projectedCrossing == nil)
    }

    @Test func scopesFilterTheSpend() {
        var w = world()
        w.addDaily("a", from: "2026-11-01", to: "2026-11-13", "10")
        w.add("o", "2026-11-13", "500", project: "pp")
        w.add("a", "2026-11-13", "1", key: "ka")
        w.tags = [Tag(orgId: "a", target: .apiKey, targetId: "ka", kind: .app)]
        #expect(status(1000, scope: .org("a"), base: w).tracking.used == 131)
        #expect(status(1000, scope: .org("o"), base: w).tracking.used == 500)
        #expect(status(1000, scope: .tag(.app), base: w).tracking.used == 1)
        #expect(status(1000, scope: .project(orgId: "o", projectId: "pp"), base: w).tracking.used == 500)
        #expect(status(1000, base: w).tracking.used == 631)
    }

    @Test func missingDataGivesNoPercent() {
        var w = World()
        w.orgs = [Org(id: "a", provider: .anthropic, displayName: "A")]
        let s = status(100, base: w)
        #expect(s.tracking.used == nil && s.tracking.percent == nil && s.thresholdsCrossed.isEmpty)
        #expect(s.tracking.reading.state == .missing)
    }
}

@Suite struct LimitAndPrepaidTests {
    private func openAIWorld() -> World {
        var w = World()
        w.addOrg("o", .openai, through: "2026-11-13")
        w.addDaily("o", from: "2026-11-01", to: "2026-11-12", "100")
        w.add("o", "2026-11-13", "70", project: "pp")
        return w
    }

    @Test func orgLimitStatusAndProjectedDate() {
        var w = openAIWorld()
        w.limits = [Limit(id: "org:hard", orgId: "o", kind: .hardLimit, thresholdCents: 200_000),
                    Limit(id: "org:alert:1", orgId: "o", kind: .alert, thresholdCents: 150_000)]
        let hard = w.snapshot.limitStatus(w.limits[0], now: now)
        #expect(hard.tracking.used == 1270 && hard.tracking.target == 2000)
        #expect(hard.projectedCrossing == day("2026-11-20"))
        #expect(hard.consequence == "Provider-enforced limit")
        let alert = w.snapshot.limitStatus(w.limits[1], now: now)
        #expect(alert.projectedCrossing == day("2026-11-15"))
        #expect(alert.consequence.contains("does not stop"))
        #expect(w.snapshot.limitStatuses(now: now).count == 2)
    }

    @Test func projectLimitUsesOnlyThatProject() {
        var w = openAIWorld()
        let l = Limit(id: "pp:hard", orgId: "o", projectId: "pp", kind: .hardLimit, thresholdCents: 5000)
        w.limits = [l]
        let s = w.snapshot.limitStatus(l, now: now)
        #expect(s.tracking.used == 70 && s.tracking.exceeded == true)
    }

    @Test func prepaidRemainingIsEnteredMinusReportedSpendSinceEntry() throws {
        var w = openAIWorld()
        w.prepaid = [PrepaidBalance(orgId: "o", amount: 1000, enteredAt: utc("2026-11-10T09:00:00Z"))]
        let p = try #require(w.snapshot.prepaidStatus(orgId: "o", now: now))
        // 11-10, 11-11, 11-12 at 100 plus today's 70.
        #expect(p.spentSinceEntry == 370)
        #expect(p.remaining == 630)
        #expect(p.dailyRate == 100)
        #expect(abs((p.daysLeft ?? 0) - 6.3) < 1e-9)
        #expect(p.projectedRunOut == day("2026-11-19"))
        #expect(!p.isDepleted && !p.spendIsPartial)
        #expect(p.label == "Estimate from a manually entered balance")
    }

    @Test func latestEntryWinsAndEarlierSpendIsIgnored() throws {
        var w = openAIWorld()
        w.prepaid = [PrepaidBalance(orgId: "o", amount: 5000, enteredAt: utc("2026-11-01T00:00:00Z")),
                     PrepaidBalance(orgId: "o", amount: 400, enteredAt: utc("2026-11-12T20:00:00Z"))]
        let p = try #require(w.snapshot.prepaidStatus(orgId: "o", now: now))
        #expect(p.enteredAmount == 400 && p.spentSinceEntry == 170 && p.remaining == 230)
    }

    @Test func depletedAndNoEntry() throws {
        var w = openAIWorld()
        #expect(w.snapshot.prepaidStatus(orgId: "o", now: now) == nil)
        w.prepaid = [PrepaidBalance(orgId: "o", amount: 50, enteredAt: utc("2026-11-12T00:00:00Z"))]
        let p = try #require(w.snapshot.prepaidStatus(orgId: "o", now: now))
        #expect(p.remaining == -120 && p.isDepleted && p.daysLeft == nil && p.projectedRunOut == nil)
    }

    @Test func prepaidWithMissingSpendDataIsFlaggedPartial() throws {
        var w = World()
        w.orgs = [Org(id: "o", provider: .openai, displayName: "O")]
        w.prepaid = [PrepaidBalance(orgId: "o", amount: 100, enteredAt: utc("2026-11-12T00:00:00Z"))]
        let p = try #require(w.snapshot.prepaidStatus(orgId: "o", now: now))
        #expect(p.spendIsPartial && p.remaining == 100 && p.daysLeft == nil)
    }
}

@Suite struct SpikeTests {
    private func flat(_ today: String) -> World {
        var w = world()
        w.addDaily("a", from: "2026-10-30", to: "2026-11-12", "100")
        w.add("a", "2026-11-13", today)
        return w
    }

    @Test func dayOverTwiceTheFourteenDayAverageIsASpike() {
        let spikes = flat("250").snapshot.spikes(now: now)
        #expect(spikes.count == 1)
        #expect(spikes[0].day == day("2026-11-13") && spikes[0].amount == 250 && spikes[0].baselineAverage == 100)
        #expect(abs(spikes[0].ratio - 2.5) < 1e-9)
    }

    @Test func exactlyTwiceIsNotASpike() {
        #expect(flat("200").snapshot.spikes(now: now).isEmpty)
        #expect(flat("200.01").snapshot.spikes(now: now).count == 1)
    }

    @Test func needsCoverageAndNonzeroAverage() {
        var unsynced = World()
        unsynced.orgs = [Org(id: "a", provider: .anthropic, displayName: "A")]
        unsynced.lines = [CostLine(day: day("2026-11-13"), orgId: "a", amount: 900, feed: .anthropicAnalytics)]
        #expect(unsynced.snapshot.spikes(now: now).isEmpty)

        var zero = world()
        zero.add("a", "2026-11-13", "900")   // fourteen covered zero days before it: mean 0, no ratio to compute
        #expect(zero.snapshot.spikes(now: now).isEmpty)
    }

    @Test func uncoveredDaysAreNeitherSpikesNorBaseline() {
        var w = world()
        w.coverage = w.coverage.map { var c = $0; c.coveredThrough = day("2026-11-12"); return c }
        w.addDaily("a", from: "2026-10-29", to: "2026-11-11", "100")
        w.add("a", "2026-11-12", "500")
        w.add("a", "2026-11-13", "9000")   // not covered yet: partial figure must not be judged
        let spikes = w.snapshot.spikes(now: now)
        #expect(spikes.map(\.day) == [day("2026-11-12")])
        #expect(spikes[0].baselineAverage == 100)
    }

    @Test func lookbackFindsEarlierSpikesToo() {
        var w = world()
        w.addDaily("a", from: "2026-10-15", to: "2026-11-13", "100")
        w.lines.removeAll { $0.day == day("2026-11-11") }
        w.add("a", "2026-11-11", "450")
        let spikes = w.snapshot.spikes(now: now, lookbackDays: 7)
        #expect(spikes.map(\.day) == [day("2026-11-11")])
        #expect(w.snapshot.spikes(now: now, lookbackDays: 2).isEmpty)
    }
}

@Suite struct ClaudeCodeQueryTests {
    @Test func joinsActivityToThePersonsReportedSpendAndKeepsEstimatesApart() {
        var w = world()
        w.entities = [Entity(orgId: "a", kind: .user, id: "user_1", name: "Alice", email: "alice@example.com")]
        w.add("a", "2026-11-12", "50", actor: "user_1")
        w.claudeCode = [
            ClaudeCodeDay(orgId: "a", day: day("2026-11-11"), actorType: .user, actorKey: "Alice@example.com", sessions: 2, linesAdded: 10, linesRemoved: 1, commits: 1, pullRequests: 0, estimatedCost: 3),
            ClaudeCodeDay(orgId: "a", day: day("2026-11-12"), actorType: .user, actorKey: "alice@example.com", sessions: 3, linesAdded: 20, linesRemoved: 2, commits: 2, pullRequests: 1, estimatedCost: dec("1.5")),
            ClaudeCodeDay(orgId: "a", day: day("2026-11-12"), actorType: .user, actorKey: "bob@example.com", sessions: 1, estimatedCost: 9),
            ClaudeCodeDay(orgId: "a", day: day("2026-11-12"), actorType: .apiKey, actorKey: "ci-bot", sessions: 4, estimatedCost: 1),
            ClaudeCodeDay(orgId: "a", day: day("2026-10-01"), actorType: .user, actorKey: "alice@example.com", sessions: 99),
        ]
        let rows = w.snapshot.claudeCodeActivity(from: day("2026-11-01"), to: day("2026-11-13"))
        #expect(rows.map(\.id) == ["bob@example.com", "alice@example.com", "ci-bot"])
        let alice = rows[1]
        #expect(alice.sessions == 5 && alice.linesAdded == 30 && alice.commits == 3 && alice.pullRequests == 1)
        #expect(alice.estimatedCost == dec("4.5") && alice.reportedSpend == 50)
        #expect(rows[0].reportedSpend == nil)
        #expect(rows[2].actorType == .apiKey && rows[2].reportedSpend == nil)
        // Org spend is untouched by the estimates.
        #expect(w.snapshot.monthToDate(now: now).amount == 50)
    }

    @Test func peopleMergeAcrossOrgsForClaudeCode() {
        var w = world()
        w.orgs.append(Org(id: "a2", provider: .anthropic, displayName: "Second"))
        w.claudeCode = [
            ClaudeCodeDay(orgId: "a", day: day("2026-11-12"), actorType: .user, actorKey: "x@y.z", sessions: 1),
            ClaudeCodeDay(orgId: "a2", day: day("2026-11-12"), actorType: .user, actorKey: "X@y.z", sessions: 2),
        ]
        let rows = w.snapshot.claudeCodeActivity(from: day("2026-11-12"), to: day("2026-11-12"))
        #expect(rows.count == 1 && rows[0].sessions == 3)
    }
}

@Suite struct CoverageTests {
    private let policy = FreshnessPolicy.default

    @Test func stateVocabulary() {
        func c(_ f: (inout Coverage) -> Void, source: SyncSource = .anthropicAnalytics) -> FreshnessState {
            var cov = Coverage(orgId: "a", source: source)
            f(&cov)
            return cov.state(now: now, policy: policy)
        }
        #expect(c { _ in } == .connected)
        #expect(c { $0.lastSuccess = utc("2026-11-13T11:30:00Z"); $0.watermark = utc("2026-11-13T10:00:00Z") } == .fresh)
        #expect(c { $0.lastSuccess = utc("2026-11-13T11:30:00Z"); $0.watermark = utc("2026-11-13T05:00:00Z") } == .delayed)
        #expect(c { $0.lastSuccess = utc("2026-11-13T11:30:00Z"); $0.watermark = utc("2026-11-12T05:00:00Z") } == .stale)
        #expect(c { $0.lastSuccess = utc("2026-11-13T05:00:00Z") } == .stale)
        #expect(c { $0.lastSuccess = utc("2026-11-13T11:30:00Z"); $0.lastError = "x" } == .error)
        #expect(c { $0.unavailable = true } == .unavailableDimension)
        #expect(c { $0.lastSuccess = utc("2026-11-13T11:30:00Z"); $0.lastFetchEmpty = true } == .noActivity)
        // No watermark means coverage unknown, not delayed.
        #expect(c({ $0.lastSuccess = utc("2026-11-13T11:30:00Z") }, source: .openaiCosts) == .fresh)
        // The last known value survives an error.
        var e = Coverage(orgId: "a", source: .openaiCosts, lastSuccess: utc("2026-11-13T09:00:00Z"), lastError: "x")
        #expect(e.hasLastKnownValue && e.state(now: now) == .error)
        e.lastSuccess = nil
        #expect(!e.hasLastKnownValue)
    }

    @Test func summaryPerOrgWorstStateAndAttention() {
        var w = world()
        w.orgs.append(Org(id: "n", provider: .openai, displayName: "Zed new"))
        w.coverage = [
            Coverage(orgId: "a", source: .anthropicAnalytics, lastSuccess: utc("2026-11-13T11:30:00Z"), watermark: utc("2026-11-13T10:00:00Z"), coveredThrough: day("2026-11-12")),
            Coverage(orgId: "a", source: .claudeCode, lastSuccess: utc("2026-11-13T11:30:00Z")),
            Coverage(orgId: "o", source: .openaiCosts, lastSuccess: utc("2026-11-13T11:30:00Z"), coveredThrough: day("2026-11-13")),
            Coverage(orgId: "o", source: .limits, lastSuccess: utc("2026-11-13T11:00:00Z"), lastError: "boom"),
        ]
        let s = w.snapshot.coverageSummary(now: now)
        #expect(s.orgs.map(\.org.id) == ["a", "o", "n"])
        #expect(s.orgs[0].state == .fresh && s.orgs[0].coveredThrough == day("2026-11-12"))
        #expect(s.orgs[1].state == .error && s.orgs[1].sources.count == 2)
        #expect(s.orgs[2].state == .connected && s.orgs[2].sources.isEmpty)
        // A failing limits call does not make the dollar figures untrustworthy.
        #expect(!s.orgs[1].needsAttention && !s.needsAttention)
        // A dollar feed in error does.
        w.coverage[2].lastError = "401"
        #expect(w.snapshot.coverageSummary(now: now).orgs[1].needsAttention && w.snapshot.coverageSummary(now: now).needsAttention)
        #expect(s.dataThrough == utc("2026-11-13T10:00:00Z"))
        #expect(s.oldestSuccess == utc("2026-11-13T11:30:00Z"))
    }

    @Test func normalAnalyticsLagAndMissingPerUserPassDoNotRaiseAttention() {
        var w = world()
        w.coverage = [
            Coverage(orgId: "a", source: .anthropicAnalytics, lastSuccess: utc("2026-11-13T11:30:00Z"), watermark: utc("2026-11-13T05:00:00Z"), coveredThrough: day("2026-11-12")),
            Coverage(orgId: "o", source: .openaiCosts, lastSuccess: utc("2026-11-13T11:30:00Z"), coveredThrough: day("2026-11-13")),
            Coverage(orgId: "o", source: .openaiCostsByUser, lastError: "400", unavailable: true),
        ]
        let s = w.snapshot.coverageSummary(now: now)
        #expect(s.orgs[0].state == .delayed && s.orgs[1].state == .unavailableDimension)
        #expect(!s.needsAttention)
    }

    @Test func healthyOrgsNeedNoAttention() {
        var w = world()
        w.coverage = w.coverage.map { var c = $0; c.lastSuccess = utc("2026-11-13T11:45:00Z"); return c }
        #expect(!w.snapshot.coverageSummary(now: now).needsAttention)
        #expect(World().snapshot.coverageSummary(now: now).orgs.isEmpty)
    }
}

@Suite struct TagTests {
    @Test func suggestionsProposeButNeverApply() {
        var w = world()
        w.entities = [
            Entity(orgId: "a", kind: .apiKey, id: "k1", name: "prod-backend"),
            Entity(orgId: "a", kind: .apiKey, id: "k2", name: "alice-laptop"),
            Entity(orgId: "a", kind: .apiKey, id: "k3", name: "local dev"),
            Entity(orgId: "a", kind: .project, id: "p1", name: "Production API"),
            Entity(orgId: "a", kind: .project, id: "p2", name: "Research"),
            Entity(orgId: "a", kind: .apiKey, id: "k4", name: "prod-or-dev"),
            Entity(orgId: "a", kind: .apiKey, id: "k5", name: "app-already-tagged"),
            Entity(orgId: "a", kind: .apiKey, id: "k6", name: "happy-key"),
            Entity(orgId: "a", kind: .user, id: "u1", name: "Alice Doe", email: "alice@example.com"),
        ]
        w.tags = [Tag(orgId: "a", target: .apiKey, targetId: "k5", kind: .team)]
        let s = w.snapshot
        let sug = Dictionary(uniqueKeysWithValues: s.tagSuggestions().map { ($0.targetId, $0.suggested) })
        #expect(sug == ["k1": .app, "k2": .team, "k3": .team, "p1": .app])
        // Nothing was applied: every line is still untagged and k5 keeps the CTO's tag.
        #expect(s.tags.count == 1)
        #expect(s.tag(orgId: "a", apiKeyId: "k1", projectId: nil) == .untagged)
        #expect(s.tag(orgId: "a", apiKeyId: "k5", projectId: nil) == .team)
        #expect(s.tagSuggestions().first { $0.targetId == "k2" }?.reason.contains("person") == true)
    }

    @Test func suggesterIsTokenBasedNotSubstring() {
        #expect(TagSuggester.suggest(name: "happy", personNames: [])?.tag == nil)
        #expect(TagSuggester.suggest(name: "my-app", personNames: [])?.tag == .app)
        #expect(TagSuggester.suggest(name: "API_PROD", personNames: [])?.tag == .app)
        #expect(TagSuggester.suggest(name: "dev", personNames: [])?.tag == .team)
        #expect(TagSuggester.suggest(name: "bob-test", personNames: ["Bob Smith"])?.tag == .team)
        #expect(TagSuggester.suggest(name: "bob-test", personNames: [])?.tag == nil)
        #expect(TagSuggester.suggest(name: "prod-dev", personNames: [])?.tag == nil)
    }
}

@Suite struct CoverageSpanTests {
    private func spanWorld(analytics: (String, String)?, legacy: (String, String)?) -> World {
        var w = World()
        w.orgs = [Org(id: "a", provider: .anthropic, displayName: "A")]
        if let a = analytics {
            w.coverage.append(Coverage(orgId: "a", source: .anthropicAnalytics, lastSuccess: utc("2026-11-13T11:00:00Z"), coveredFrom: day(a.0), coveredThrough: day(a.1)))
        }
        if let l = legacy {
            w.coverage.append(Coverage(orgId: "a", source: .anthropicLegacy, lastSuccess: utc("2026-11-13T11:00:00Z"), coveredFrom: day(l.0), coveredThrough: day(l.1)))
        }
        return w
    }

    @Test func abuttingFeedsFormOneUnbrokenSpan() {
        let s = spanWorld(analytics: ("2026-01-01", "2026-11-12"), legacy: ("2026-11-13", "2026-11-13")).snapshot
        #expect(s.coverageSpans(orgId: "a").count == 1)
        #expect(s.total(from: day("2026-10-01"), to: day("2026-11-13")).state == .noActivity)
    }

    @Test func aGapBetweenFeedsMakesTheSpanningTotalPartial() {
        // Backfill stopped in May; legacy covers only the last 60 days.
        let s = spanWorld(analytics: ("2026-01-01", "2026-05-04"), legacy: ("2026-09-14", "2026-11-13")).snapshot
        #expect(s.coverageSpans(orgId: "a").count == 2)
        #expect(s.total(from: day("2026-05-01"), to: day("2026-11-13")).state == .partial)
        #expect(s.total(from: day("2026-10-01"), to: day("2026-11-13")).state == .noActivity)
        #expect(s.total(from: day("2026-02-01"), to: day("2026-04-30")).state == .noActivity)
        #expect(s.total(from: day("2026-06-01"), to: day("2026-08-31")).state == .missing)
        #expect(s.total(from: day("2026-06-01"), to: day("2026-08-31")).amount == nil)
    }

    @Test func daysBeforeTheFirstCoveredDayAreNotZero() {
        let s = spanWorld(analytics: ("2026-11-10", "2026-11-12"), legacy: nil).snapshot
        #expect(s.total(from: day("2026-11-01"), to: day("2026-11-12")).state == .partial)
        #expect(s.total(from: day("2026-11-01"), to: day("2026-11-05")).amount == nil)
        #expect(s.total(from: day("2026-11-10"), to: day("2026-11-12")).state == .noActivity)
    }

    @Test func recentOnlyCoverageIsPartialForTheMonth() {
        let s = spanWorld(analytics: nil, legacy: ("2026-11-11", "2026-11-13")).snapshot
        #expect(s.monthToDate(now: now).state == .partial)
        #expect(s.today(now: now).state == .noActivity)
    }
}
