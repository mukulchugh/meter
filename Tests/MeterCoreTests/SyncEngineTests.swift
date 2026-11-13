import Foundation
import Synchronization
import Testing
@testable import MeterCore

private let start = utc("2026-11-13T12:00:00Z")
private let adminKey = "sk-ant-admin01-test"
private let openAIKey = "sk-admin-test"

/// A canned Anthropic Admin API. Every analytics window returns one $100 row on its first day.
@Sendable private func anthropicAPI(_ r: HTTPRequest) -> HTTPResponse {
    switch r.path {
    case "/v1/organizations/analytics/cost":
        let d = r.query("starting_at")!.prefix(10)
        return json(#"{"data":[{"starting_at":"\#(d)T00:00:00Z","ending_at":"x","group":{"model":"claude-opus-5","actor":"user_01ALICE"},"cost":{"currency":"USD","amount":"10000.000000"}}],"has_more":false,"next_page":null,"data_refreshed_at":"2026-11-13T09:00:00Z"}"#)
    case "/v1/organizations/cost_report":
        let from = UTCDay(string: r.query("starting_at")!)!, to = UTCDay(string: r.query("ending_at")!)!
        let buckets = UTCDay.range(from: from, through: to.adding(-1)).map {
            #"{"starting_at":"\#($0.string)T00:00:00Z","ending_at":"x","results":[{"amount":"5000","currency":"USD","model":"claude-opus-5","workspace_id":null}]}"#
        }
        return json(#"{"data":[\#(buckets.joined(separator: ","))],"has_more":false,"next_page":null}"#)
    case "/v1/organizations/usage_report/claude_code":
        let d = r.query("starting_at")!
        return json(#"{"data":[{"actor":{"type":"user_actor","email_address":"alice@example.com"},"core_metrics":{"num_sessions":1,"lines_of_code":{"added":10,"removed":2},"commits_by_claude_code":1,"pull_requests_by_claude_code":0},"model_breakdown":[{"estimated_cost":{"amount":"100"}}]}],"has_more":false,"date":"\#(d)"}"#)
    case "/v1/organizations/workspaces": return Fixture.response("anthropic_workspaces")
    case "/v1/organizations/api_keys": return Fixture.response("anthropic_api_keys")
    case "/v1/organizations/users": return Fixture.response("anthropic_users")
    default: return HTTPResponse(status: 404)
    }
}

/// A canned OpenAI admin API. Every cost window returns one $10 row on its first day.
@Sendable private func openAIAPI(_ r: HTTPRequest) -> HTTPResponse { openAIAPI(r, refuseBefore: nil) }

/// `refuseBefore` makes costs requests starting earlier than that day fail with 400, like a shallow history.
@Sendable private func openAIAPI(_ r: HTTPRequest, refuseBefore: UTCDay?) -> HTTPResponse {
    switch r.path {
    case "/v1/organization/costs":
        let s = Int(r.query("start_time")!)!
        if let floor = refuseBefore, s < floor.unixStart { return json(#"{"error":{"message":"start_time too old"}}"#, status: 400) }
        let user = r.queryAll("group_by[]") == ["user_id"]
        let result = user ? #"{"amount":{"value":4,"currency":"usd"},"user_id":"user-alice"}"# :
            #"{"amount":{"value":10,"currency":"usd"},"line_item":"gpt-6-astra, input_tokens","project_id":"proj_prod","api_key_id":"key_1"}"#
        return json(#"{"object":"page","data":[{"start_time":\#(s),"end_time":\#(s + 86400),"results":[\#(result)]}],"has_more":false}"#)
    case "/v1/organization/projects": return Fixture.response("openai_projects")
    case "/v1/organization/projects/proj_prod/api_keys": return Fixture.response("openai_project_api_keys")
    case "/v1/organization/projects/proj_old/api_keys": return json(#"{"data":[],"has_more":false}"#)
    case "/v1/organization/users": return Fixture.response("openai_users")
    case "/v1/organization/spend_limit": return Fixture.response("openai_spend_limit")
    case "/v1/organization/spend_alerts": return Fixture.response("openai_spend_alerts")
    default: return HTTPResponse(status: 404, body: Data(#"{"error":{"message":"none"}}"#.utf8))
    }
}

private struct Rig {
    let store: MeterStore
    let secrets: InMemorySecrets
    let transport: FakeTransport
    let clock: TestClock
    let engine: SyncEngine
    let anthropic = Org(id: "org-a", provider: .anthropic, displayName: "Acme Anthropic")
    let openai = Org(id: "org-o", provider: .openai, displayName: "Acme OpenAI")

    init(config: SyncConfig = SyncConfig(), withKeys: Bool = true,
         handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) async throws {
        store = try MeterStore.inMemory()
        secrets = InMemorySecrets()
        transport = FakeTransport(handler)
        clock = TestClock(start)
        let clock = clock
        engine = SyncEngine(store: store, secrets: secrets, clientFactory: defaultClientFactory(transport: transport), config: config,
                            now: { clock.now })
        try await store.upsertOrg(anthropic)
        try await store.upsertOrg(openai)
        if withKeys {
            try secrets.write(adminKey, for: anthropic.keychainRef)
            try secrets.write(openAIKey, for: openai.keychainRef)
        }
    }

    func snapshot() async throws -> MeterSnapshot { try await store.snapshot() }
}

private func routed(_ r: HTTPRequest) throws -> HTTPResponse {
    r.path.hasPrefix("/v1/organization/") ? openAIAPI(r) : anthropicAPI(r)
}

@Suite struct AnthropicSyncTests {
    @Test func firstSyncBackfillsInThirtyOneDayWindowsAndKeepsPartialDaysOut() async throws {
        let rig = try await Rig(handler: routed)
        let report = await rig.engine.refresh(org: rig.anthropic)
        #expect(report.outcomes[.anthropicAnalytics] == .updated(lines: 11))
        #expect(report.outcomes.values.allSatisfy { if case .failed = $0 { false } else { true } })

        let analytics = rig.transport.requests(path: "/v1/organizations/analytics/cost")
        // 2026-01-01 through 2026-11-13 is 317 days: eleven windows of at most 31.
        #expect(analytics.count == 11)
        #expect(analytics.first?.query("starting_at") == "2026-01-01T00:00:00Z")
        #expect(analytics.last?.query("ending_at") == "2026-11-14T00:00:00Z")
        for r in analytics {
            let a = UTCDay(string: r.query("starting_at")!)!, b = UTCDay(string: r.query("ending_at")!)!
            #expect(a.days(until: b) <= 31)
        }

        let s = try await rig.snapshot()
        let cov = try #require(s.coverage.first { $0.orgId == "org-a" && $0.source == .anthropicAnalytics })
        #expect(cov.coveredThrough == day("2026-11-12"))     // 09:00 watermark: 11-13 is partial
        #expect(cov.watermark == utc("2026-11-13T09:00:00Z"))
        #expect(cov.lastSuccess == start && cov.lastError == nil)

        // Legacy fills today only; days the analytics feed covers are not stored twice.
        let legacy = s.lines.filter { $0.feed == .anthropicLegacy }
        #expect(legacy.count == 1 && legacy[0].day == day("2026-11-13") && legacy[0].amount == 50)
        #expect(s.lines.filter { $0.feed == .anthropicAnalytics }.count == 11)
        let anthropicOnly = CostFilter(provider: .anthropic)
        #expect(s.today(now: start, filter: anthropicOnly).amount == 50)
        #expect(s.monthToDate(now: start, filter: anthropicOnly).amount == 150)
        #expect(s.today(now: start, filter: anthropicOnly).state == .value)
        // The OpenAI org has not synced, so the combined total is partial rather than quietly lower.
        #expect(s.today(now: start).state == .partial)

        // Claude Code, names, coverage rows for every source.
        #expect(rig.transport.requests(path: "/v1/organizations/usage_report/claude_code").count == 30)
        #expect(s.claudeCode.count == 30 && s.claudeCode[0].estimatedCost == 1)
        #expect(s.entities.count == 2 + 1 + 1)
        let summary = s.coverageSummary(now: start)
        #expect(summary.orgs.first { $0.org.id == "org-a" }?.state == .fresh)
        #expect(summary.orgs.first { $0.org.id == "org-a" }?.sources.count == 4)
    }

    @Test func incrementalSyncRefetchesTrailingThreeDaysAndIsIdempotent() async throws {
        let rig = try await Rig(handler: anthropicAPI)
        _ = await rig.engine.refresh(org: rig.anthropic)
        let before = try await rig.snapshot()
        rig.transport.reset()
        rig.clock.advance(3600)

        let report = await rig.engine.refresh(org: rig.anthropic)
        #expect(report.outcomes[.anthropicAnalytics] == .updated(lines: 1))
        let analytics = rig.transport.requests(path: "/v1/organizations/analytics/cost")
        #expect(analytics.count == 1)
        // Covered through 11-12, so trailing three days start on 11-10.
        #expect(analytics[0].query("starting_at") == "2026-11-10T00:00:00Z")
        #expect(rig.transport.requests(path: "/v1/organizations/usage_report/claude_code").map { $0.query("starting_at") }
                == ["2026-11-11", "2026-11-12", "2026-11-13"])
        #expect(rig.transport.requests(path: "/v1/organizations/cost_report").count == 1)

        let after = try await rig.snapshot()
        #expect(after.lines.filter { $0.feed == .anthropicAnalytics }.count == before.lines.filter { $0.feed == .anthropicAnalytics }.count + 1)
        #expect(after.claudeCode.count == 30)

        // A third, identical sync changes nothing.
        _ = await rig.engine.refresh(org: rig.anthropic)
        let third = try await rig.snapshot()
        #expect(third.lines.count == after.lines.count)
        #expect(Set(third.lines) == Set(after.lines))
    }

    @Test func restatedAnalyticsDayReplacesInsteadOfAdding() async throws {
        let amount = Mutex("10000.000000")
        let rig = try await Rig { r in
            if r.path == "/v1/organizations/analytics/cost" {
                let a = amount.withLock { $0 }
                return json(#"{"data":[{"starting_at":"2026-11-11T00:00:00Z","group":{"model":"m"},"cost":{"amount":"\#(a)"}}],"has_more":false,"data_refreshed_at":"2026-11-13T09:00:00Z"}"#)
            }
            return anthropicAPI(r)
        }
        _ = await rig.engine.refresh(org: rig.anthropic)
        func nov11() async throws -> [Decimal] {
            try await rig.snapshot().lines.filter { $0.feed == .anthropicAnalytics && $0.day == day("2026-11-11") }.map(\.amount)
        }
        #expect(try await nov11() == [100])
        amount.withLock { $0 = "12500.000000" }
        rig.clock.advance(3600)
        _ = await rig.engine.refresh(org: rig.anthropic)
        #expect(try await nov11() == [125])
    }

    @Test func cadenceForegroundLegacyEveryMinuteBackgroundFifteen() async throws {
        let rig = try await Rig(handler: anthropicAPI)
        await rig.engine.setForeground(true)
        await rig.engine.syncDue()
        #expect(rig.transport.requests(path: "/v1/organizations/analytics/cost").count == 11)
        rig.transport.reset()

        await rig.engine.syncDue()
        #expect(rig.transport.requests.isEmpty)                      // nothing is due yet

        rig.clock.advance(61)
        await rig.engine.syncDue()
        #expect(rig.transport.requests.map(\.path) == ["/v1/organizations/cost_report"])   // foreground: legacy only
        rig.transport.reset()

        await rig.engine.setForeground(false)
        rig.clock.advance(61)
        await rig.engine.syncDue()
        #expect(rig.transport.requests.isEmpty)                      // background: 15 minutes

        rig.clock.advance(15 * 60)
        await rig.engine.syncDue()
        #expect(rig.transport.requests.map(\.path) == ["/v1/organizations/cost_report"])
        rig.transport.reset()

        rig.clock.advance(3600)
        await rig.engine.syncDue()
        let paths = Set(rig.transport.requests.map(\.path))
        #expect(paths.contains("/v1/organizations/analytics/cost") && paths.contains("/v1/organizations/usage_report/claude_code"))
        #expect(!paths.contains("/v1/organizations/workspaces"))     // names are daily
        rig.transport.reset()

        rig.clock.advance(86_400)
        await rig.engine.syncDue()
        #expect(rig.transport.requests(path: "/v1/organizations/workspaces").count == 1)
    }

    @Test func rateLimitHonoursRetryAfterThenRecovers() async throws {
        let limited = Mutex(true)
        let rig = try await Rig { r in
            if r.path == "/v1/organizations/analytics/cost", limited.withLock({ $0 }) {
                return json(#"{"error":{"message":"slow down"}}"#, status: 429, headers: ["Retry-After": "120"])
            }
            return anthropicAPI(r)
        }
        let first = await rig.engine.refresh(org: rig.anthropic)
        #expect(first.outcomes[.anthropicAnalytics] == .failed(.rateLimited(retryAfter: 120)))
        #expect(first.outcomes[.anthropicLegacy] != nil)
        var cov = try await rig.store.coverage(orgId: "org-a", source: .anthropicAnalytics)
        #expect(cov.errorKind == "rateLimited" && cov.state(now: start) == .error && cov.lastSuccess == nil)
        // Legacy alone covered three days. A month total over that must say partial, not complete.
        let limitedSnap = try await rig.snapshot()
        let mtd = limitedSnap.monthToDate(now: start, filter: CostFilter(provider: .anthropic))
        #expect(mtd.state == .partial && mtd.amount == 150)
        #expect(limitedSnap.today(now: start, filter: CostFilter(provider: .anthropic)).state == .value)
        let calls = rig.transport.requests(path: "/v1/organizations/analytics/cost").count
        #expect(calls == 1)

        // Inside the window: no request is made at all.
        rig.clock.advance(60)
        let blocked = await rig.engine.refresh(org: rig.anthropic)
        #expect(blocked.outcomes[.anthropicAnalytics] == .backedOff(until: start.addingTimeInterval(120)))
        #expect(rig.transport.requests(path: "/v1/organizations/analytics/cost").count == calls)

        // After it, and with the limit lifted, the sync resumes and the error clears.
        limited.withLock { $0 = false }
        rig.clock.advance(61)
        let ok = await rig.engine.refresh(org: rig.anthropic)
        #expect(ok.outcomes[.anthropicAnalytics] == .updated(lines: 11))
        cov = try await rig.store.coverage(orgId: "org-a", source: .anthropicAnalytics)
        #expect(cov.lastError == nil && cov.errorKind == nil && cov.lastSuccess != nil)
    }

    @Test func rateLimitWithoutRetryAfterBacksOffExponentially() async throws {
        let rig = try await Rig { r in
            r.path == "/v1/organizations/analytics/cost" ? json("{}", status: 429) : anthropicAPI(r)
        }
        _ = await rig.engine.refresh(org: rig.anthropic)                  // blocked 60 s
        rig.clock.advance(61)
        let second = await rig.engine.refresh(org: rig.anthropic)         // tries again, fails, blocked 120 s
        #expect(second.outcomes[.anthropicAnalytics] == .failed(.rateLimited(retryAfter: nil)))
        rig.clock.advance(61)
        let third = await rig.engine.refresh(org: rig.anthropic)
        if case .backedOff = third.outcomes[.anthropicAnalytics] {} else { Issue.record("expected still backed off, got \(String(describing: third.outcomes[.anthropicAnalytics]))") }
        rig.clock.advance(60)
        let fourth = await rig.engine.refresh(org: rig.anthropic)
        #expect(fourth.outcomes[.anthropicAnalytics] == .failed(.rateLimited(retryAfter: nil)))
    }

    @Test func authErrorBecomesCoverageStateAndStopsTheOrg() async throws {
        let rig = try await Rig { _ in json("{}", status: 401) }
        let report = await rig.engine.refresh(org: rig.anthropic)
        #expect(report.outcomes[.anthropicAnalytics] == .failed(.auth(.invalidKey, .anthropic)))
        #expect(report.outcomes[.anthropicLegacy] == .skipped("credential rejected"))
        #expect(rig.transport.requests.count == 1)                       // no hammering with a rejected key

        let s = try await rig.snapshot()
        let cov = try #require(s.coverage.first { $0.source == .anthropicAnalytics })
        #expect(cov.errorKind == "auth" && cov.lastError?.contains("rejected") == true)
        #expect(cov.state(now: start) == .error && !cov.hasLastKnownValue)
        #expect(s.coverageSummary(now: start).needsAttention)
        // Missing data, not zero.
        #expect(s.today(now: start, filter: CostFilter(orgIds: ["org-a"])).amount == nil)
    }

    @Test func nonAdminKeyGetsAClearMessageAndLastKnownValuesSurvive() async throws {
        let ok = Mutex(true)
        let rig = try await Rig { r in ok.withLock { $0 } ? anthropicAPI(r) : json("{}", status: 403) }
        _ = await rig.engine.refresh(org: rig.anthropic)
        let before = try await rig.snapshot().monthToDate(now: start).amount
        #expect(before == 150)

        ok.withLock { $0 = false }
        rig.clock.advance(7200)
        try rig.secrets.write("sk-ant-api03-notadmin", for: rig.anthropic.keychainRef)
        _ = await rig.engine.refresh(org: rig.anthropic)
        let s = try await rig.snapshot()
        let cov = try #require(s.coverage.first { $0.source == .anthropicAnalytics })
        #expect(cov.lastError?.contains("can't read") == true)
        #expect(cov.hasLastKnownValue && cov.state(now: rig.clock.now) == .error)
        // Old lines stay; the total keeps its last known value.
        #expect(s.monthToDate(now: rig.clock.now).amount == 150)
    }

    @Test func missingSecretIsAnAuthError() async throws {
        let rig = try await Rig(withKeys: false) { _ in json("{}") }
        let report = await rig.engine.refresh(org: rig.anthropic)
        #expect(report.outcomes[.anthropicAnalytics] == .failed(.auth(.noKey, .anthropic)))
        #expect(rig.transport.requests.isEmpty)
        #expect(try await rig.store.coverage(orgId: "org-a", source: .anthropicAnalytics).lastError?.contains("No key") == true)
    }

    @Test func betaEndpointRefusalFallsBackToLegacyHistory() async throws {
        let rig = try await Rig { r in
            r.path == "/v1/organizations/analytics/cost" ? json(#"{"error":{"message":"unknown beta"}}"#, status: 400) : anthropicAPI(r)
        }
        let report = await rig.engine.refresh(org: rig.anthropic)
        #expect(report.outcomes[.anthropicAnalytics] == .failed(.badRequest("unknown beta")))
        let s = try await rig.snapshot()
        let cov = try #require(s.coverage.first { $0.source == .anthropicAnalytics })
        #expect(cov.unavailable && cov.state(now: start) == .unavailableDimension)
        // Legacy now carries a full year of history so totals still work.
        let legacyRequest = try #require(rig.transport.requests(path: "/v1/organizations/cost_report").first)
        #expect(legacyRequest.query("starting_at") == "2025-11-14T00:00:00Z")
        #expect(s.lines.filter { $0.feed == .anthropicLegacy }.count == 365)
        #expect(s.monthToDate(now: start).amount == 650)       // 13 days at $50
    }

    @Test func analyticsFailingAfterSuccessNeverDoubleCountsWithLegacy() async throws {
        let analyticsOK = Mutex(true)
        let rig = try await Rig { r in
            if r.path == "/v1/organizations/analytics/cost", !analyticsOK.withLock({ $0 }) {
                return json(#"{"error":{"message":"beta retired"}}"#, status: 404)
            }
            return anthropicAPI(r)
        }
        _ = await rig.engine.refresh(org: rig.anthropic)
        let filter = CostFilter(provider: .anthropic)
        let before = try await rig.snapshot().monthToDate(now: start, filter: filter)
        #expect(before.amount == 150 && before.state == .value)

        analyticsOK.withLock { $0 = false }
        rig.clock.advance(7200)
        let report = await rig.engine.refresh(org: rig.anthropic)
        #expect(report.outcomes[.anthropicAnalytics] == .failed(.notFound("beta retired")))
        let s = try await rig.snapshot()
        // Legacy resumed from the day after analytics coverage, not over days analytics holds.
        let legacyDays = Set(s.lines.filter { $0.feed == .anthropicLegacy }.map(\.day))
        #expect(legacyDays == [day("2026-11-13")])
        let after = s.monthToDate(now: rig.clock.now, filter: filter)
        #expect(after.amount == before.amount && after.state == .value)
    }

    @Test func legacyStartsTheDayAfterALaggingAnalyticsWatermark() async throws {
        // The watermark is five days old: analytics covers through 11-07, so legacy must fill 11-08 to today.
        let rig = try await Rig { r in
            if r.path == "/v1/organizations/analytics/cost" {
                let d = r.query("starting_at")!.prefix(10)
                return json(#"{"data":[{"starting_at":"\#(d)T00:00:00Z","group":{"model":"m"},"cost":{"amount":"10000.000000"}}],"has_more":false,"data_refreshed_at":"2026-11-08T03:00:00Z"}"#)
            }
            return anthropicAPI(r)
        }
        _ = await rig.engine.refresh(org: rig.anthropic)
        let legacy = try #require(rig.transport.requests(path: "/v1/organizations/cost_report").first)
        #expect(legacy.query("starting_at") == "2026-11-08T00:00:00Z")
        let s = try await rig.snapshot()
        #expect(Set(s.lines.filter { $0.feed == .anthropicLegacy }.map(\.day)) == Set(UTCDay.range(from: day("2026-11-08"), through: day("2026-11-13"))))
        #expect(s.monthToDate(now: start, filter: CostFilter(provider: .anthropic)).state == .value)
    }

    @Test func backfillStoppingMidwayLeavesAGapThatReadsPartial() async throws {
        let calls = Mutex(0)
        let rig = try await Rig { r in
            if r.path == "/v1/organizations/analytics/cost", calls.withLock({ $0 += 1; return $0 }) == 5 { return HTTPResponse(status: 500) }
            return anthropicAPI(r)
        }
        let report = await rig.engine.refresh(org: rig.anthropic)
        #expect(report.outcomes[.anthropicAnalytics] == .failed(.server(status: 500)))
        let s = try await rig.snapshot()
        let cov = try #require(s.coverage.first { $0.source == .anthropicAnalytics })
        #expect(cov.coveredFrom == day("2026-01-01") && cov.coveredThrough == day("2026-05-04"))
        let filter = CostFilter(provider: .anthropic)
        #expect(s.total(from: day("2026-03-01"), to: day("2026-11-13"), filter: filter).state == .partial)
        #expect(s.total(from: day("2026-06-01"), to: day("2026-08-31"), filter: filter).state == .missing)
        // The retry resumes where it left off instead of starting a year back.
        rig.clock.advance(120)
        let again = await rig.engine.refresh(org: rig.anthropic)
        #expect(again.outcomes[.anthropicAnalytics] != nil)
    }

    @Test func pageCursorsWithPlusAreEncoded() async throws {
        let t = FakeTransport { r in
            r.query("page") == nil
                ? json(#"{"data":[],"has_more":true,"next_page":"a+b/c=="}"#)
                : json(#"{"data":[],"has_more":false}"#)
        }
        let c = AnthropicClient(orgId: "a", apiKey: adminKey, transport: t)
        _ = try await c.fetchCosts(from: day("2026-10-01"), to: day("2026-10-02"))
        let second = try #require(t.requests.last)
        #expect(second.url.absoluteString.contains("page=a%2Bb/c%3D%3D"))
        #expect(second.query("page") == "a+b/c==")
    }

    @Test func startAndStopRunTheLoop() async throws {
        var config = SyncConfig()
        config.tick = 0.01
        let rig = try await Rig(config: config, handler: anthropicAPI)
        await rig.engine.start()
        await rig.engine.start()                                         // idempotent
        var ok = false
        for _ in 0..<400 {
            if let c = try? await rig.store.coverage(orgId: "org-a", source: .entities), c.lastSuccess != nil { ok = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ok)
        await rig.engine.stop()
        try await Task.sleep(for: .milliseconds(100))
        let n = rig.transport.requests.count
        try await Task.sleep(for: .milliseconds(150))
        #expect(rig.transport.requests.count == n)
    }
}

@Suite struct OpenAISyncTests {
    @Test func firstSyncPagesThroughOneYearInWindowsOf180Days() async throws {
        let rig = try await Rig(handler: openAIAPI)
        let report = await rig.engine.refresh(org: rig.openai)
        #expect(report.outcomes[.openaiCosts] == .updated(lines: 3))
        let costs = rig.transport.requests(path: "/v1/organization/costs").filter { $0.queryAll("group_by[]") != ["user_id"] }
        #expect(costs.count == 3)                                        // 365 days: 180 + 180 + 5
        #expect(costs[0].query("start_time") == String(day("2025-11-14").unixStart))
        #expect(costs.last?.query("end_time") == String(day("2026-11-14").unixStart))
        #expect(costs.allSatisfy { $0.query("limit") == "180" && $0.query("bucket_width") == "1d" })
        #expect(rig.transport.requests(path: "/v1/organization/costs").count == 6)   // plus the per-user pass

        let s = try await rig.snapshot()
        #expect(s.lines.filter { $0.feed == .openaiCosts }.count == 3)
        #expect(s.lines.filter { $0.feed == .openaiCostsByUser }.count == 3)
        // The per-user pass is the same dollars again: it never counts toward totals.
        #expect(s.total(from: day("2025-11-14"), to: day("2026-11-13")).amount == 30)
        #expect(s.lines.first { $0.feed == .openaiCosts }?.model == "gpt-6-astra")

        let cov = try #require(s.coverage.first { $0.source == .openaiCosts })
        #expect(cov.coveredThrough == day("2026-11-13") && cov.watermark == nil)
        // No watermark: freshness is fresh-by-fetch, coverage unknown rather than implied.
        #expect(cov.state(now: start) == .fresh)

        #expect(s.limits.count == 2)     // org hard limit and alert; the canned API 404s project limits (none set)
        #expect(rig.transport.requests(path: "/v1/organization/projects/proj_prod/spend_limit").count == 1)
        #expect(rig.transport.requests(path: "/v1/organization/projects/proj_old/spend_limit").isEmpty)   // archived
        #expect(s.entities.contains { $0.kind == .apiKey && $0.id == "key_1" })
        #expect(s.people(from: day("2026-01-01"), to: day("2026-11-13")).people.first?.email == "alice@example.com")
    }

    @Test func incrementalSyncRefetchesTrailingDays() async throws {
        let rig = try await Rig(handler: openAIAPI)
        _ = await rig.engine.refresh(org: rig.openai)
        rig.transport.reset()
        rig.clock.advance(3600)
        _ = await rig.engine.refresh(org: rig.openai)
        let costs = rig.transport.requests(path: "/v1/organization/costs").filter { $0.queryAll("group_by[]") != ["user_id"] }
        #expect(costs.count == 1)
        #expect(costs[0].query("start_time") == String(day("2026-11-11").unixStart))
    }

    @Test func refusedHistoryIsSkippedAndNoted() async throws {
        let rig = try await Rig { openAIAPI($0, refuseBefore: day("2026-01-01")) }
        _ = await rig.engine.refresh(org: rig.openai)
        // The canned API refuses start times before 2026-01-01, so the oldest window (2025-11-14) is refused.
        let s = try await rig.snapshot()
        let cov = try #require(s.coverage.first { $0.source == .openaiCosts })
        #expect(cov.note?.contains("History") == true)
        #expect(cov.lastError == nil)
        #expect(s.lines.filter { $0.feed == .openaiCosts }.map(\.day).min()! >= day("2026-01-01"))
        // The refused span is not reported as quiet days.
        #expect(cov.coveredFrom == day("2026-05-13"))
        let f = CostFilter(provider: .openai)
        #expect(s.total(from: day("2026-01-01"), to: day("2026-11-13"), filter: f).state == .partial)
        #expect(s.total(from: day("2025-11-14"), to: day("2026-02-01"), filter: f).state == .missing)
        #expect(s.total(from: day("2026-05-13"), to: day("2026-11-13"), filter: f).state == .value)
    }

    @Test func perUserPassRefusalIsAnUnavailableDimensionNotAnOutage() async throws {
        let rig = try await Rig { r in
            r.queryAll("group_by[]") == ["user_id"] ? json(#"{"error":{"message":"cannot group by user_id"}}"#, status: 400) : openAIAPI(r)
        }
        let report = await rig.engine.refresh(org: rig.openai)
        #expect(report.outcomes[.openaiCosts] == .updated(lines: 3))
        let byUser = try await rig.store.coverage(orgId: "org-o", source: .openaiCostsByUser)
        #expect(byUser.state(now: start) == .unavailableDimension)
        // Dollar totals are still fully covered.
        let s = try await rig.snapshot()
        #expect(s.today(now: start).state != .missing || s.monthToDate(now: start).state != .missing)
        #expect(s.coverageSummary(now: start).orgs.first { $0.org.id == "org-o" }?.coveredThrough == day("2026-11-13"))
    }

    @Test func serverErrorBacksOff() async throws {
        let rig = try await Rig { r in r.path == "/v1/organization/costs" ? HTTPResponse(status: 503) : openAIAPI(r) }
        let first = await rig.engine.refresh(org: rig.openai)
        #expect(first.outcomes[.openaiCosts] == .failed(.server(status: 503)))
        let again = await rig.engine.refresh(org: rig.openai)
        #expect(again.outcomes[.openaiCosts] == .backedOff(until: start.addingTimeInterval(60)))
    }

    @Test func networkErrorIsRecordedWithoutBlocking() async throws {
        let rig = try await Rig { _ in throw OfflineError() }
        let first = await rig.engine.refresh(org: rig.openai)
        guard case .failed(.network) = first.outcomes[.openaiCosts] else { Issue.record("expected network failure"); return }
        let cov = try await rig.store.coverage(orgId: "org-o", source: .openaiCosts)
        #expect(cov.errorKind == "network" && cov.state(now: start) == .error)
        let retry = await rig.engine.refresh(org: rig.openai)
        guard case .failed(.network) = retry.outcomes[.openaiCosts] else { Issue.record("expected another attempt"); return }
    }

    @Test func refreshAllCoversEveryOrg() async throws {
        let rig = try await Rig(handler: routed)
        let reports = await rig.engine.refreshAll()
        #expect(Set(reports.map(\.orgId)) == ["org-a", "org-o"])
    }
}
