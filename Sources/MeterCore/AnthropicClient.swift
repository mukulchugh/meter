import Foundation

/// Anthropic Admin API client. Paths, headers and encodings follow RESEARCH.md sections 2.1, 5 and 6.
///
/// Sources:
/// - https://platform.claude.com/docs/en/api/beta/organization/analytics/cost/list
/// - https://platform.claude.com/docs/en/api/beta/organization/cost_report/retrieve
/// - https://platform.claude.com/docs/en/manage-claude/claude-code-analytics-api
public struct AnthropicClient: ProviderClient {
    public let provider = Provider.anthropic
    public let maxCostWindowDays = 31

    // RESEARCH.md section 2.1: "anthropic-version: 2026-10-21 (value used in current docs)" and the beta
    // header for the analytics endpoint.
    static let version = "2026-10-21"
    static let analyticsBeta = "analytics-usage-cost-2026-08-24"
    public static let baseURL = URL(string: "https://api.anthropic.com")!

    private let orgId: String
    private let core: APIClientCore

    public init(orgId: String, apiKey: String, transport: any HTTPTransport, baseURL: URL = AnthropicClient.baseURL) {
        self.orgId = orgId
        self.core = APIClientCore(
            transport: transport, baseURL: baseURL, provider: .anthropic,
            baseHeaders: [
                "x-api-key": apiKey,
                "anthropic-version": Self.version,
                "user-agent": "Meter/1.0 (local menu bar app)",
            ],
            looksAdmin: apiKey.hasPrefix("sk-ant-admin"))
    }

    /// Signed in with the `ant` CLI: `authorization: Bearer <token>` instead of `x-api-key`. The Admin API,
    /// Usage and Cost and Claude Code analytics endpoints accept an `org:admin` token (RESEARCH.md section
    /// 13). The token is held only by this value, which lives for one sync pass.
    public init(orgId: String, bearerToken: String, transport: any HTTPTransport, baseURL: URL = AnthropicClient.baseURL) {
        self.orgId = orgId
        self.core = APIClientCore(
            transport: transport, baseURL: baseURL, provider: .anthropic,
            baseHeaders: [
                "authorization": "Bearer \(bearerToken)",
                "anthropic-version": Self.version,
                "user-agent": "Meter/1.0 (local menu bar app)",
            ],
            looksAdmin: true, bearer: true)
    }

    private func iso(_ d: Date) -> String { ISODate.format(d) }

    // MARK: Costs

    /// `GET /v1/organizations/analytics/cost` (beta). RESEARCH.md section 2.1, "New" column.
    /// Rows, not buckets. `cost.amount` is cents as a decimal string with six decimals, post-discount
    /// and pre-credit. Empty buckets produce no rows.
    public func fetchCosts(from: UTCDay, to: UTCDay) async throws -> CostFetch {
        var query: [(String, String)] = [
            ("starting_at", iso(from.start)), ("ending_at", iso(to.end)), ("bucket_width", "1d"), ("limit", "1000"),
        ]
        // Five dimensions is the documented maximum. cost_type and token_type are left out on purpose.
        for g in ["model", "api_key_id", "workspace_id", "actor", "service_tier"] { query.append(("group_by[]", g)) }

        let pages = try await core.pages { cursor in
            var q = query
            if let cursor { q.append(("page", cursor)) }
            let json = try await core.get("v1/organizations/analytics/cost", query: q,
                                          extraHeaders: ["anthropic-beta": Self.analyticsBeta])
            return (json, json["next_page"].string)
        }
        var lines = [CostLine]()
        var watermark: Date?
        for page in pages {
            if let w = page["data_refreshed_at"].string.flatMap(ISODate.parse) {
                watermark = watermark.map { min($0, w) } ?? w
            }
            for row in page["data"].array {
                guard let day = row["starting_at"].string.flatMap({ UTCDay(string: $0) }) else {
                    throw ProviderError.unexpectedResponse("analytics/cost row without starting_at")
                }
                guard let amount = row["cost"]["amount"].decimal.map({ $0 / 100 }) else {
                    throw ProviderError.unexpectedResponse("analytics/cost row without cost.amount")
                }
                guard amount != 0 else { continue }
                let g = row["group"]
                lines.append(CostLine(
                    day: day, orgId: orgId, amount: amount,
                    currency: row["cost"]["currency"].string ?? "USD", feed: .anthropicAnalytics,
                    model: g["model"].string, apiKeyId: g["api_key_id"].string, projectId: g["workspace_id"].string,
                    actor: Self.actorId(g["actor"]), serviceTier: g["service_tier"].string))
            }
        }
        return CostFetch(lines: CostLine.mergingDuplicates(lines), watermark: watermark)
    }

    /// The `group.actor` shape is not shown in RESEARCH.md. Accept a bare string id or an object.
    static func actorId(_ actor: JSON) -> String? {
        if let s = actor.string { return s }
        for key in ["user_id", "id", "api_key_id", "email_address", "email"] {
            if let s = actor[key].string { return s }
        }
        return nil
    }

    /// Legacy `GET /v1/organizations/cost_report` (RESEARCH.md section 2.1, "Legacy" column): buckets with
    /// fresh partial days; `amount` is cents as a decimal string; no per-key split.
    public func fetchRecentCosts(from: UTCDay, to: UTCDay) async throws -> CostFetch? {
        let query: [(String, String)] = [
            ("starting_at", iso(from.start)), ("ending_at", iso(to.end)), ("bucket_width", "1d"), ("limit", "31"),
            ("group_by[]", "workspace_id"), ("group_by[]", "description"),
        ]
        let pages = try await core.pages { cursor in
            var q = query
            if let cursor { q.append(("page", cursor)) }
            let json = try await core.get("v1/organizations/cost_report", query: q)
            return (json, json["next_page"].string)
        }
        var lines = [CostLine]()
        for page in pages {
            for bucket in page["data"].array {
                guard let day = bucket["starting_at"].string.flatMap({ UTCDay(string: $0) }) else {
                    throw ProviderError.unexpectedResponse("cost_report bucket without starting_at")
                }
                for r in bucket["results"].array {
                    guard let amount = r["amount"].decimal.map({ $0 / 100 }) else {
                        throw ProviderError.unexpectedResponse("cost_report result without amount")
                    }
                    guard amount != 0 else { continue }
                    lines.append(CostLine(
                        day: day, orgId: orgId, amount: amount, currency: r["currency"].string ?? "USD",
                        feed: .anthropicLegacy, model: r["model"].string, projectId: r["workspace_id"].string,
                        serviceTier: r["service_tier"].string, lineItem: nil))
                }
            }
        }
        // Several description rows (input, output, cache) share a model: sum them.
        return CostFetch(lines: CostLine.mergingDuplicates(lines), watermark: nil)
    }

    // MARK: Claude Code

    /// `GET /v1/organizations/usage_report/claude_code`, one UTC day per call. RESEARCH.md section 6.
    /// The record nesting (`core_metrics`, `model_breakdown`) is not in RESEARCH.md; both nested and flat
    /// layouts are accepted. `estimated_cost.amount` is cents.
    public func fetchClaudeCode(day: UTCDay) async throws -> [ClaudeCodeDay]? {
        let pages = try await core.pages { cursor in
            var q: [(String, String)] = [("starting_at", day.string), ("limit", "1000")]
            if let cursor { q.append(("page", cursor)) }
            let json = try await core.get("v1/organizations/usage_report/claude_code", query: q)
            return (json, json["next_page"].string)
        }
        struct K: Hashable { let type: ClaudeCodeDay.ActorType; let key: String }
        var sums = [K: ClaudeCodeDay]()
        var order = [K]()
        for page in pages {
            for rec in page["data"].array {
                let actor = rec["actor"]
                let k: K
                if let email = actor["email_address"].string {
                    k = K(type: .user, key: email.lowercased())
                } else if let name = actor["api_key_name"].string {
                    k = K(type: .apiKey, key: name)
                } else { continue }
                let metrics = rec["core_metrics"].isObject ? rec["core_metrics"] : rec
                var cost = Decimal(0)
                for m in rec["model_breakdown"].array {
                    cost += m["estimated_cost"]["amount"].decimal ?? 0
                }
                if rec["model_breakdown"].array.isEmpty { cost += rec["estimated_cost"]["amount"].decimal ?? 0 }
                var d = sums[k] ?? ClaudeCodeDay(orgId: orgId, day: day, actorType: k.type, actorKey: k.key)
                if sums[k] == nil { order.append(k) }
                d.sessions += metrics["num_sessions"].int ?? 0
                d.linesAdded += metrics["lines_of_code"]["added"].int ?? 0
                d.linesRemoved += metrics["lines_of_code"]["removed"].int ?? 0
                d.commits += metrics["commits_by_claude_code"].int ?? 0
                d.pullRequests += metrics["pull_requests_by_claude_code"].int ?? 0
                d.estimatedCost += cost / 100
                sums[k] = d
            }
        }
        return order.compactMap { sums[$0] }
    }

    // MARK: Names

    /// Workspaces, API keys and users. RESEARCH.md section 5. List pagination uses `after_id` with the
    /// response's `last_id` (assumed, the standard Anthropic list contract).
    public func fetchEntities() async throws -> [Entity] {
        var out = [Entity]()
        for w in try await list("v1/organizations/workspaces", extra: [("include_default", "true")]) {
            guard let id = w["id"].string else { continue }
            out.append(Entity(orgId: orgId, kind: .project, id: id, name: w["name"].string ?? id,
                              archived: !w["archived_at"].isNull))
        }
        for k in try await list("v1/organizations/api_keys", extra: []) {
            guard let id = k["id"].string else { continue }
            out.append(Entity(orgId: orgId, kind: .apiKey, id: id, name: k["name"].string ?? id,
                              parentId: k["workspace_id"].string,
                              ownerId: k["created_by"]["id"].string,
                              archived: k["status"].string == "archived"))
        }
        for u in try await list("v1/organizations/users", extra: []) {
            guard let id = u["id"].string else { continue }
            let email = u["email"].string?.lowercased()
            out.append(Entity(orgId: orgId, kind: .user, id: id, name: u["name"].string ?? email ?? id, email: email))
        }
        return out
    }

    private func list(_ path: String, extra: [(String, String)]) async throws -> [JSON] {
        let pages = try await core.pages { cursor in
            var q: [(String, String)] = [("limit", "1000")] + extra
            if let cursor { q.append(("after_id", cursor)) }
            let json = try await core.get(path, query: q)
            return (json, json["last_id"].string ?? json["next_page"].string)
        }
        return pages.flatMap { $0["data"].array }
    }
}

extension ISODate {
    static func format(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}
