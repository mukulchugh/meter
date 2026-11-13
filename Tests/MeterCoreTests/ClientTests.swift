import Foundation
import Testing
@testable import MeterCore

private let adminKey = "sk-ant-admin01-test"
private let openAIKey = "sk-admin-test"

@Suite struct AnthropicClientTests {
    @Test func analyticsParsesDimensionsAndCents() async throws {
        let t = FakeTransport { _ in Fixture.response("anthropic_analytics_cost") }
        let c = AnthropicClient(orgId: "a", apiKey: adminKey, transport: t)
        let f = try await c.fetchCosts(from: day("2026-09-01"), to: day("2026-09-30"))

        // Row 0: $412.80, no dimensions but model. Rows 1 and 2 share every dimension and are summed.
        #expect(f.lines.count == 2)
        let opus = try #require(f.lines.first { $0.model == "claude-opus-5" })
        #expect(opus.amount == dec("412.8"))
        #expect(opus.day == day("2026-09-01"))
        #expect(opus.feed == .anthropicAnalytics && opus.source == .reported)
        let sonnet = try #require(f.lines.first { $0.model == "claude-sonnet-5" })
        #expect(sonnet.amount == dec("12.34567892"))
        #expect(sonnet.apiKeyId == "apikey_01AAA" && sonnet.projectId == "wrkspc_01PROD")
        #expect(sonnet.actor == "user_01ALICE" && sonnet.serviceTier == "standard")
        #expect(f.watermark == utc("2026-10-01T06:00:00Z"))
    }

    @Test func requestShape() async throws {
        let t = FakeTransport { _ in Fixture.response("anthropic_analytics_cost") }
        let c = AnthropicClient(orgId: "a", apiKey: adminKey, transport: t)
        _ = try await c.fetchCosts(from: day("2026-09-01"), to: day("2026-09-30"))
        let r = try #require(t.requests.first)
        #expect(r.path == "/v1/organizations/analytics/cost")
        #expect(r.headers["x-api-key"] == adminKey)
        #expect(r.headers["anthropic-version"] == "2026-10-21")
        #expect(r.headers["anthropic-beta"] == "analytics-usage-cost-2026-08-24")
        #expect(r.query("starting_at") == "2026-09-01T00:00:00Z")
        #expect(r.query("ending_at") == "2026-10-01T00:00:00Z")
        #expect(r.queryAll("group_by[]") == ["model", "api_key_id", "workspace_id", "actor", "service_tier"])
    }

    @Test func analyticsPaginatesAndTakesOldestWatermark() async throws {
        let t = FakeTransport { r in
            r.query("page") == "page_ABC" ? Fixture.response("anthropic_analytics_cost_page2") : Fixture.response("anthropic_analytics_cost_page1")
        }
        let c = AnthropicClient(orgId: "a", apiKey: adminKey, transport: t)
        let f = try await c.fetchCosts(from: day("2026-10-01"), to: day("2026-10-02"))
        #expect(t.requests.count == 2)
        #expect(f.lines.map(\.amount).reduce(0, +) == 300)
        // The conservative watermark: the earlier of the two pages.
        #expect(f.watermark == utc("2026-10-03T04:00:00Z"))
    }

    @Test func repeatedCursorIsAnErrorNotALoop() async {
        let t = FakeTransport { _ in Fixture.response("anthropic_analytics_cost_page1") }
        let c = AnthropicClient(orgId: "a", apiKey: adminKey, transport: t)
        await #expect(throws: ProviderError.self) { try await c.fetchCosts(from: day("2026-10-01"), to: day("2026-10-02")) }
        #expect(t.requests.count == 2)
    }

    @Test func legacyCostReportSumsDescriptionRowsAndSkipsEmptyDays() async throws {
        let t = FakeTransport { r in
            r.query("page") != nil ? Fixture.response("anthropic_cost_report_page2") : Fixture.response("anthropic_cost_report")
        }
        let c = AnthropicClient(orgId: "a", apiKey: adminKey, transport: t)
        let f = try #require(try await c.fetchRecentCosts(from: day("2025-08-01"), to: day("2025-08-03")))
        #expect(t.requests.allSatisfy { $0.path == "/v1/organizations/cost_report" })
        #expect(t.requests.first?.headers["anthropic-beta"] == nil)
        // 123.78912 + 76.21088 cents = exactly 200 cents = $2.00 for the same model and workspace.
        let opus = try #require(f.lines.first { $0.model == "claude-opus-5-5" })
        #expect(opus.amount == 2)
        #expect(opus.feed == .anthropicLegacy)
        // Page 2: default workspace has null workspace_id; 50 cents.
        let web = try #require(f.lines.first { $0.day == day("2025-08-03") })
        #expect(web.amount == dec("0.5") && web.projectId == nil)
        #expect(f.lines.count == 2)
        #expect(f.watermark == nil)
    }

    @Test func claudeCodeSumsSplitsAndConvertsCents() async throws {
        let t = FakeTransport { _ in Fixture.response("anthropic_claude_code") }
        let c = AnthropicClient(orgId: "a", apiKey: adminKey, transport: t)
        let days = try #require(try await c.fetchClaudeCode(day: day("2026-11-10")))
        #expect(t.requests.first?.query("starting_at") == "2026-11-10")
        let alice = try #require(days.first { $0.actorKey == "alice@example.com" })
        #expect(alice.actorType == .user)
        #expect(alice.sessions == 6 && alice.linesAdded == 130 && alice.linesRemoved == 30)
        #expect(alice.commits == 2 && alice.pullRequests == 1)
        // 250 + 50.5 + 100 cents = $4.005
        #expect(alice.estimatedCost == dec("4.005"))
        let bot = try #require(days.first { $0.actorType == .apiKey })
        #expect(bot.actorKey == "ci-bot" && bot.estimatedCost == dec("0.1"))
        #expect(days.count == 2)
    }

    @Test func entityLists() async throws {
        let t = FakeTransport { r in
            switch r.path {
            case "/v1/organizations/workspaces": Fixture.response("anthropic_workspaces")
            case "/v1/organizations/api_keys": Fixture.response("anthropic_api_keys")
            case "/v1/organizations/users": Fixture.response("anthropic_users")
            default: HTTPResponse(status: 404)
            }
        }
        let c = AnthropicClient(orgId: "a", apiKey: adminKey, transport: t)
        let e = try await c.fetchEntities()
        #expect(t.requests(path: "/v1/organizations/workspaces").first?.query("include_default") == "true")
        #expect(e.first { $0.id == "wrkspc_01PROD" }?.name == "Production")
        #expect(e.first { $0.id == "wrkspc_01OLD" }?.archived == true)
        let key = try #require(e.first { $0.id == "apikey_01AAA" })
        #expect(key.parentId == "wrkspc_01PROD" && key.ownerId == "user_01ALICE" && key.kind == .apiKey)
        let user = try #require(e.first { $0.kind == .user })
        #expect(user.email == "alice@example.com" && user.name == "Alice Doe")
    }

    @Test func errorMapping() async throws {
        func fetch(status: Int, key: String, headers: [String: String] = [:], body: String = "{}") async -> ProviderError? {
            let t = FakeTransport { _ in json(body, status: status, headers: headers) }
            let c = AnthropicClient(orgId: "a", apiKey: key, transport: t)
            do { _ = try await c.fetchCosts(from: day("2026-10-01"), to: day("2026-10-02")); return nil }
            catch { return error as? ProviderError }
        }
        // A key without the admin prefix: say so.
        let notAdmin = await fetch(status: 401, key: "sk-ant-api03-xyz")
        #expect(notAdmin == .auth(.notAdminKey, .anthropic))
        #expect(notAdmin?.message.contains("can't read spend") == true)
        // An admin-looking key that is refused: expired or revoked.
        #expect(await fetch(status: 401, key: adminKey) == .auth(.invalidKey, .anthropic))
        // 403 with an admin key: the Admin API is not available (individual accounts).
        let unavailable = await fetch(status: 403, key: adminKey, body: String(decoding: Fixture.data("error_anthropic_403"), as: UTF8.self))
        #expect(unavailable == .auth(.adminAPIUnavailable, .anthropic))
        #expect(unavailable?.message.contains("individual accounts") == true)
        #expect(await fetch(status: 429, key: adminKey, headers: ["Retry-After": "42"]) == .rateLimited(retryAfter: 42))
        #expect(await fetch(status: 429, key: adminKey) == .rateLimited(retryAfter: nil))
        #expect(await fetch(status: 503, key: adminKey) == .server(status: 503))
        #expect(await fetch(status: 400, key: adminKey, body: #"{"error":{"message":"bad range"}}"#) == .badRequest("bad range"))
        #expect(await fetch(status: 200, key: adminKey, body: "not json") == .unexpectedResponse("invalid JSON from v1/organizations/analytics/cost"))
    }

    @Test func networkFailureBecomesNetworkError() async {
        let t = FakeTransport { _ in throw OfflineError() }
        let c = AnthropicClient(orgId: "a", apiKey: adminKey, transport: t)
        do {
            _ = try await c.fetchCosts(from: day("2026-10-01"), to: day("2026-10-02"))
            Issue.record("expected a throw")
        } catch let e as ProviderError {
            guard case .network = e else { Issue.record("expected network, got \(e)"); return }
        } catch { Issue.record("wrong error \(error)") }
    }
}

@Suite struct OpenAIClientTests {
    @Test func costsParseDollarsAndModel() async throws {
        let t = FakeTransport { _ in Fixture.response("openai_costs") }
        let c = OpenAIClient(orgId: "o", apiKey: openAIKey, transport: t)
        let f = try await c.fetchCosts(from: day("2024-11-01"), to: day("2024-11-01"))
        let r = try #require(t.requests.first)
        #expect(r.path == "/v1/organization/costs")
        #expect(r.headers["authorization"] == "Bearer \(openAIKey)")
        #expect(r.query("start_time") == "1730419200" && r.query("end_time") == "1730505600")
        #expect(r.query("bucket_width") == "1d" && r.query("limit") == "180")
        #expect(r.queryAll("group_by[]") == ["project_id", "api_key_id", "line_item"])

        #expect(f.lines.count == 3)
        #expect(f.lines.allSatisfy { $0.day == day("2024-11-01") && $0.currency == "USD" && $0.feed == .openaiCosts })
        #expect(f.lines.first { $0.lineItem == nil }?.amount == dec("0.06"))
        let astra = try #require(f.lines.first { $0.model == "gpt-6-astra" })
        #expect(astra.amount == dec("1.234567") && astra.projectId == "proj_prod" && astra.apiKeyId == "key_1")
        // No comma in the line item, so the model stays unknown.
        #expect(f.lines.first { $0.lineItem == "Code interpreter sessions" }?.model == nil)
        #expect(f.watermark == nil)
    }

    @Test func modelFromLineItem() {
        #expect(OpenAIClient.model(fromLineItem: "gpt-6-astra, input_tokens") == "gpt-6-astra")
        #expect(OpenAIClient.model(fromLineItem: "  o4-mini ,output_tokens") == "o4-mini")
        #expect(OpenAIClient.model(fromLineItem: "Web search tool calls") == nil)
        #expect(OpenAIClient.model(fromLineItem: ", input_tokens") == nil)
    }

    @Test func costsPaginate() async throws {
        let t = FakeTransport { r in r.query("page") == "page_2" ? Fixture.response("openai_costs_page2") : Fixture.response("openai_costs_page1") }
        let c = OpenAIClient(orgId: "o", apiKey: openAIKey, transport: t)
        let f = try await c.fetchCosts(from: day("2024-11-01"), to: day("2024-11-02"))
        #expect(t.requests.count == 2)
        #expect(f.lines.map(\.amount).reduce(0, +) == dec("3.75"))
        #expect(Set(f.lines.map(\.day)) == [day("2024-11-01"), day("2024-11-02")])
    }

    @Test func byUserPassIsASeparateFeed() async throws {
        let t = FakeTransport { _ in Fixture.response("openai_costs_by_user") }
        let c = OpenAIClient(orgId: "o", apiKey: openAIKey, transport: t)
        let f = try #require(try await c.fetchSupplementalCosts(from: day("2024-11-01"), to: day("2024-11-01")))
        #expect(t.requests.first?.queryAll("group_by[]") == ["user_id"])
        #expect(f.lines.first?.feed == .openaiCostsByUser && f.lines.first?.actor == "user-alice")
    }

    @Test func entityLists() async throws {
        let t = FakeTransport { r in
            switch r.path {
            case "/v1/organization/projects": Fixture.response("openai_projects")
            case "/v1/organization/projects/proj_prod/api_keys", "/v1/organization/projects/proj_old/api_keys": Fixture.response("openai_project_api_keys")
            case "/v1/organization/users": Fixture.response("openai_users")
            default: HTTPResponse(status: 404)
            }
        }
        let c = OpenAIClient(orgId: "o", apiKey: openAIKey, transport: t)
        let e = try await c.fetchEntities()
        #expect(e.first { $0.id == "proj_old" }?.archived == true)
        let key = try #require(e.first { $0.kind == .apiKey })
        #expect(key.name == "backend" && key.ownerId == "user-alice" && key.lastUsedAt == Date(timeIntervalSince1970: 1_730_419_200))
        #expect(e.first { $0.kind == .user }?.email == "alice@example.com")
        #expect(t.requests(path: "/v1/organization/projects").first?.query("include_archived") == "true")
    }

    @Test func limitsAreCentsAnd404MeansNone() async throws {
        let t = FakeTransport { r in
            switch r.path {
            case "/v1/organization/spend_limit": Fixture.response("openai_spend_limit")
            case "/v1/organization/spend_alerts": Fixture.response("openai_spend_alerts")
            default: HTTPResponse(status: 404, body: Data(#"{"error":{"message":"none"}}"#.utf8))
            }
        }
        let c = OpenAIClient(orgId: "o", apiKey: openAIKey, transport: t)
        let l = try #require(try await c.fetchLimits(projectIds: ["proj_prod"]))
        #expect(l.count == 2)
        let hard = try #require(l.first { $0.kind == .hardLimit })
        #expect(hard.thresholdCents == 500_000 && hard.thresholdUSD == 5000 && hard.projectId == nil)
        let alert = try #require(l.first { $0.kind == .alert })
        #expect(alert.thresholdCents == 300_000)
    }

    @Test func errorMapping() async {
        func fetch(status: Int, key: String, headers: [String: String] = [:]) async -> ProviderError? {
            let t = FakeTransport { _ in json("{}", status: status, headers: headers) }
            let c = OpenAIClient(orgId: "o", apiKey: key, transport: t)
            do { _ = try await c.fetchCosts(from: day("2026-10-01"), to: day("2026-10-02")); return nil }
            catch { return error as? ProviderError }
        }
        #expect(await fetch(status: 401, key: "sk-proj-abc") == .auth(.notAdminKey, .openai))
        #expect(await fetch(status: 401, key: openAIKey) == .auth(.invalidKey, .openai))
        #expect(await fetch(status: 403, key: openAIKey) == .auth(.forbidden, .openai))
        #expect(await fetch(status: 429, key: openAIKey, headers: ["retry-after": "7"]) == .rateLimited(retryAfter: 7))
        #expect(await fetch(status: 500, key: openAIKey) == .server(status: 500))
    }
}
