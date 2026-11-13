import Foundation

/// OpenAI organization admin client. RESEARCH.md sections 2.2, 5 and 7.
///
/// Sources: openai/openai-openapi `openapi.yaml` (`/organization/costs` L12085, spend limits L30090 and
/// L30231, spend alerts L17305) and https://developers.openai.com/api/reference/administration/overview.md
public struct OpenAIClient: ProviderClient {
    public let provider = Provider.openai
    public let maxCostWindowDays = 180

    public static let baseURL = URL(string: "https://api.openai.com")!

    private let orgId: String
    private let core: APIClientCore

    public init(orgId: String, apiKey: String, transport: any HTTPTransport, baseURL: URL = OpenAIClient.baseURL) {
        self.orgId = orgId
        self.core = APIClientCore(
            transport: transport, baseURL: baseURL, provider: .openai,
            baseHeaders: ["authorization": "Bearer \(apiKey)", "user-agent": "Meter/1.0 (local menu bar app)"],
            looksAdmin: apiKey.hasPrefix("sk-admin"))
    }

    // MARK: Costs

    public func fetchCosts(from: UTCDay, to: UTCDay) async throws -> CostFetch {
        try await costs(from: from, to: to, groups: ["project_id", "api_key_id", "line_item"], feed: .openaiCosts)
    }

    /// RESEARCH.md section 2.2: `user_id` combinations may return 400, so users come from their own pass.
    public func fetchSupplementalCosts(from: UTCDay, to: UTCDay) async throws -> CostFetch? {
        try await costs(from: from, to: to, groups: ["user_id"], feed: .openaiCostsByUser)
    }

    /// `GET /v1/organization/costs`: `start_time` unix seconds (required), `end_time` exclusive, 1d buckets,
    /// `limit` up to 180 buckets, `amount.value` is a JSON number in dollars (parsed from its token text).
    private func costs(from: UTCDay, to: UTCDay, groups: [String], feed: CostFeed) async throws -> CostFetch {
        var query: [(String, String)] = [
            ("start_time", String(from.unixStart)), ("end_time", String(to.adding(1).unixStart)),
            ("bucket_width", "1d"), ("limit", "180"),
        ]
        for g in groups { query.append(("group_by[]", g)) }
        let pages = try await core.pages { cursor in
            var q = query
            if let cursor { q.append(("page", cursor)) }
            let json = try await core.get("v1/organization/costs", query: q)
            return (json, json["next_page"].string)
        }
        var lines = [CostLine]()
        for page in pages {
            for bucket in page["data"].array {
                guard let start = bucket["start_time"].int else {
                    throw ProviderError.unexpectedResponse("costs bucket without start_time")
                }
                let day = UTCDay(Date(timeIntervalSince1970: TimeInterval(start)))
                for r in bucket["results"].array {
                    guard let amount = r["amount"]["value"].decimal else {
                        throw ProviderError.unexpectedResponse("costs result without amount.value")
                    }
                    guard amount != 0 else { continue }
                    let item = r["line_item"].string
                    lines.append(CostLine(
                        day: day, orgId: orgId, amount: amount, currency: r["amount"]["currency"].string ?? "usd",
                        feed: feed, model: item.flatMap(Self.model(fromLineItem:)),
                        apiKeyId: r["api_key_id"].string, projectId: r["project_id"].string,
                        actor: r["user_id"].string, lineItem: item))
                }
            }
        }
        return CostFetch(lines: CostLine.mergingDuplicates(lines), watermark: nil)
    }

    /// Line items look like `gpt-6-astra, input_tokens` (RESEARCH.md section 2.2). The model is the text
    /// before the first comma. Anything without a comma ("Code interpreter sessions") has no model, so it
    /// stays unknown rather than guessed.
    public static func model(fromLineItem item: String) -> String? {
        let parts = item.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let model = parts[0].trimmingCharacters(in: .whitespaces)
        return model.isEmpty ? nil : model
    }

    // MARK: Names

    public func fetchEntities() async throws -> [Entity] {
        var out = [Entity]()
        let projects = try await list("v1/organization/projects", extra: [("include_archived", "true")], limit: 100)
        for p in projects {
            guard let id = p["id"].string else { continue }
            out.append(Entity(orgId: orgId, kind: .project, id: id, name: p["name"].string ?? id,
                              archived: p["status"].string == "archived"))
        }
        // No org-wide key list exists in the spec (RESEARCH.md section 5): list keys per project.
        for p in projects {
            guard let pid = p["id"].string else { continue }
            for k in try await list("v1/organization/projects/\(pid)/api_keys", extra: [], limit: 100) {
                guard let id = k["id"].string else { continue }
                out.append(Entity(orgId: orgId, kind: .apiKey, id: id, name: k["name"].string ?? id, parentId: pid,
                                  ownerId: k["owner"]["user"]["id"].string,
                                  lastUsedAt: k["last_used_at"].int.map { Date(timeIntervalSince1970: TimeInterval($0)) }))
            }
        }
        for u in try await list("v1/organization/users", extra: [], limit: 100) {
            guard let id = u["id"].string else { continue }
            let email = u["email"].string?.lowercased()
            out.append(Entity(orgId: orgId, kind: .user, id: id, name: u["name"].string ?? email ?? id, email: email))
        }
        return out
    }

    private func list(_ path: String, extra: [(String, String)], limit: Int) async throws -> [JSON] {
        let pages = try await core.pages { cursor in
            var q: [(String, String)] = [("limit", String(limit))] + extra
            if let cursor { q.append(("after", cursor)) }
            let json = try await core.get(path, query: q)
            return (json, json["last_id"].string ?? json["next_page"].string)
        }
        return pages.flatMap { $0["data"].array }
    }

    // MARK: Limits

    /// Org and project hard limits plus alerts, all integer cents. 404 means none is set (RESEARCH.md section 7).
    /// The per-project alerts path is assumed to mirror the per-project limit path.
    public func fetchLimits(projectIds: [String]) async throws -> [Limit]? {
        var out = [Limit]()
        out += try await limit(path: "v1/organization/spend_limit", projectId: nil)
        out += try await alerts(path: "v1/organization/spend_alerts", projectId: nil)
        for pid in projectIds {
            out += try await limit(path: "v1/organization/projects/\(pid)/spend_limit", projectId: pid)
            out += try await alerts(path: "v1/organization/projects/\(pid)/spend_alerts", projectId: pid)
        }
        return out
    }

    private func limit(path: String, projectId: String?) async throws -> [Limit] {
        do {
            let json = try await core.get(path)
            guard let cents = json["threshold_amount"].int else { return [] }
            return [Limit(id: "\(projectId ?? "org"):hard", orgId: orgId, projectId: projectId, kind: .hardLimit,
                          thresholdCents: cents, currency: json["currency"].string ?? "USD",
                          interval: json["interval"].string ?? "month")]
        } catch ProviderError.notFound { return [] }
    }

    private func alerts(path: String, projectId: String?) async throws -> [Limit] {
        do {
            let json = try await core.get(path)
            // Shape not shown in RESEARCH.md: accept a list envelope or a single object.
            let items = json["data"].array.isEmpty && !json["threshold_amount"].isNull ? [json] : json["data"].array
            return items.compactMap { a in
                guard let cents = a["threshold_amount"].int else { return nil }
                return Limit(id: "\(projectId ?? "org"):alert:\(a["id"].string ?? String(cents))", orgId: orgId,
                             projectId: projectId, kind: .alert, thresholdCents: cents,
                             currency: a["currency"].string ?? "USD", interval: a["interval"].string ?? "month")
            }
        } catch ProviderError.notFound { return [] }
    }
}
