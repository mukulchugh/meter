import Foundation
import MeterCore

/// Demo mode (`METER_DEMO=1`): an in-memory store filled by running the real sync engine against a fake
/// provider, so screenshots and tests need no keys and no network.
public enum DemoData {
    public static let anthropicOrgId = "demo-anthropic"
    public static let openAIOrgId = "demo-openai"

    public static func factory(now: Date) -> ProviderClientFactory {
        { org, _ in DemoClient(provider: org.provider, orgId: org.id, now: now) }
    }

    /// Orgs, secrets, synced history, tags, budgets and a prepaid balance.
    public static func seed(store: MeterStore, secrets: any Secrets, engine: SyncEngine, now: Date) async throws {
        let orgs = [
            Org(id: anthropicOrgId, provider: .anthropic, displayName: "Acme Console"),
            Org(id: openAIOrgId, provider: .openai, displayName: "Acme OpenAI"),
        ]
        for o in orgs {
            try secrets.write("demo-admin-key", for: o.keychainRef)
            try await store.upsertOrg(o)
        }
        _ = await engine.refreshAll()
        try await store.setTag(Tag(orgId: anthropicOrgId, target: .apiKey, targetId: "key_prod", kind: .app))
        try await store.setTag(Tag(orgId: anthropicOrgId, target: .project, targetId: "ws_prod", kind: .app))
        try await store.setTag(Tag(orgId: anthropicOrgId, target: .apiKey, targetId: "key_ana", kind: .team))
        try await store.setTag(Tag(orgId: openAIOrgId, target: .project, targetId: "proj_app", kind: .app))
        try await store.upsertBudget(Budget(id: "demo-budget", name: "Monthly AI spend", scope: .overall, amount: 15_000))
        try await store.upsertBudget(Budget(id: "demo-budget-app", name: "Production app", scope: .tag(.app), amount: 9_000))
        try await store.setPrepaid(PrepaidBalance(orgId: openAIOrgId, amount: 2_000, enteredAt: now.addingTimeInterval(-10 * 86_400)))
    }
}

/// Deterministic fake provider. Amounts come from a hash of the day, in whole cents.
struct DemoClient: ProviderClient {
    let provider: Provider
    let orgId: String
    let now: Date

    var maxCostWindowDays: Int { provider == .anthropic ? 31 : 180 }
    private var today: UTCDay { UTCDay(now) }

    private func cents(_ base: Int, _ day: UTCDay, salt: Int) -> Decimal {
        let h = abs((day.daysSinceEpoch &* 2_654_435_761 &+ salt &* 40_503) % 1000)
        var c = base * (800 + h * 4 / 10) / 1000
        let weekday = ((day.daysSinceEpoch + 4) % 7 + 7) % 7
        if weekday == 0 || weekday == 6 { c = c * 6 / 10 }
        if day == today.adding(-3) && salt == 1 { c *= 5 }
        return Decimal(c) / 100
    }

    private func line(_ day: UTCDay, _ feed: CostFeed, _ amount: Decimal, model: String? = nil, key: String? = nil,
                      project: String? = nil, actor: String? = nil, item: String? = nil) -> CostLine {
        CostLine(day: day, orgId: orgId, amount: amount, feed: feed, model: model, apiKeyId: key, projectId: project,
                 actor: actor, lineItem: item)
    }

    private func analytics(_ d: UTCDay) -> [CostLine] {
        let f = CostFeed.anthropicAnalytics
        return [
            line(d, f, cents(11_000, d, salt: 1), model: "claude-opus-5", key: "key_prod", project: "ws_prod"),
            line(d, f, cents(7_000, d, salt: 2), model: "claude-sonnet-5", key: "key_prod", project: "ws_prod"),
            line(d, f, cents(4_500, d, salt: 3), model: "claude-sonnet-5", key: "key_ana", project: "ws_dev", actor: "user_ana"),
            line(d, f, cents(3_000, d, salt: 4), model: "claude-sonnet-5", key: "key_ben", project: "ws_dev", actor: "user_ben"),
            line(d, f, cents(1_500, d, salt: 5), model: "claude-haiku-5", key: "key_ci", project: "ws_dev"),
            line(d, f, cents(500, d, salt: 11), model: "claude-sonnet-5", key: "key_ci", project: "ws_dev", actor: "user_ghost"),
        ]
    }

    private func legacy(_ d: UTCDay) -> [CostLine] {
        let f = CostFeed.anthropicLegacy
        return [
            line(d, f, cents(11_000, d, salt: 1), model: "claude-opus-5", project: "ws_prod"),
            line(d, f, cents(7_000, d, salt: 2), model: "claude-sonnet-5", project: "ws_prod"),
            line(d, f, cents(9_000, d, salt: 3), model: "claude-sonnet-5", project: "ws_dev"),
        ]
    }

    private func openAI(_ d: UTCDay) -> [CostLine] {
        let f = CostFeed.openaiCosts
        return [
            line(d, f, cents(9_000, d, salt: 6), model: "gpt-6-astra", key: "key_oa_prod", project: "proj_app", item: "gpt-6-astra, input tokens"),
            line(d, f, cents(6_000, d, salt: 7), model: "gpt-6-astra", key: "key_oa_prod", project: "proj_app", item: "gpt-6-astra, output tokens"),
            line(d, f, cents(2_500, d, salt: 8), model: "gpt-6-mini", key: "key_oa_lab", project: "proj_lab", item: "gpt-6-mini, input tokens"),
        ]
    }

    func fetchCosts(from: UTCDay, to: UTCDay) async throws -> CostFetch {
        let days = UTCDay.range(from: from, through: to)
        switch provider {
        case .anthropic: return CostFetch(lines: days.flatMap(analytics), watermark: now.addingTimeInterval(-2 * 3600))
        case .openai: return CostFetch(lines: days.flatMap(openAI))
        }
    }

    func fetchRecentCosts(from: UTCDay, to: UTCDay) async throws -> CostFetch? {
        provider == .anthropic ? CostFetch(lines: UTCDay.range(from: from, through: to).flatMap(legacy)) : nil
    }

    func fetchSupplementalCosts(from: UTCDay, to: UTCDay) async throws -> CostFetch? {
        guard provider == .openai else { return nil }
        let lines = UTCDay.range(from: from, through: to).flatMap { d in
            [line(d, .openaiCostsByUser, cents(1_500, d, salt: 9), actor: "user-ana"),
             line(d, .openaiCostsByUser, cents(2_500, d, salt: 10), actor: "user-cy")]
        }
        return CostFetch(lines: lines)
    }

    func fetchClaudeCode(day: UTCDay) async throws -> [ClaudeCodeDay]? {
        guard provider == .anthropic else { return nil }
        let w = ((day.daysSinceEpoch + 4) % 7 + 7) % 7
        guard w != 0 && w != 6 else { return [] }
        func d(_ who: String, type: ClaudeCodeDay.ActorType = .user, _ s: Int, _ a: Int, _ r: Int, _ c: Int, _ p: Int, _ cost: Decimal) -> ClaudeCodeDay {
            ClaudeCodeDay(orgId: orgId, day: day, actorType: type, actorKey: who, sessions: s, linesAdded: a, linesRemoved: r,
                          commits: c, pullRequests: p, estimatedCost: cost)
        }
        return [d("ana@acme.dev", 6, 420, 130, 5, 2, 32), d("ben@acme.dev", 3, 180, 60, 2, 1, 14),
                d("dee@acme.dev", 2, 90, 20, 1, 0, 6), d("ci-evals", type: .apiKey, 12, 0, 0, 0, 0, 9)]
    }

    func fetchEntities() async throws -> [Entity] {
        switch provider {
        case .anthropic:
            [Entity(orgId: orgId, kind: .project, id: "ws_prod", name: "Production"),
             Entity(orgId: orgId, kind: .project, id: "ws_dev", name: "Developers"),
             Entity(orgId: orgId, kind: .apiKey, id: "key_prod", name: "prod-api", parentId: "ws_prod", lastUsedAt: now.addingTimeInterval(-600)),
             Entity(orgId: orgId, kind: .apiKey, id: "key_ana", name: "ana-dev", parentId: "ws_dev", ownerId: "user_ana", lastUsedAt: now.addingTimeInterval(-3_600)),
             Entity(orgId: orgId, kind: .apiKey, id: "key_ben", name: "ben-local", parentId: "ws_dev", ownerId: "user_ben", lastUsedAt: now.addingTimeInterval(-7_200)),
             Entity(orgId: orgId, kind: .apiKey, id: "key_ci", name: "ci-evals", parentId: "ws_dev", lastUsedAt: now.addingTimeInterval(-1_800)),
             Entity(orgId: orgId, kind: .apiKey, id: "key_old", name: "legacy-batch", parentId: "ws_prod", lastUsedAt: now.addingTimeInterval(-60 * 86_400)),
             Entity(orgId: orgId, kind: .user, id: "user_ana", name: "Ana Silva", email: "ana@acme.dev"),
             Entity(orgId: orgId, kind: .user, id: "user_ben", name: "Ben Okafor", email: "ben@acme.dev")]
        case .openai:
            [Entity(orgId: orgId, kind: .project, id: "proj_app", name: "Support Bot"),
             Entity(orgId: orgId, kind: .project, id: "proj_lab", name: "Research Lab"),
             Entity(orgId: orgId, kind: .apiKey, id: "key_oa_prod", name: "prod-key", parentId: "proj_app", lastUsedAt: now.addingTimeInterval(-300)),
             Entity(orgId: orgId, kind: .apiKey, id: "key_oa_lab", name: "dev-cy", parentId: "proj_lab", ownerId: "user-cy", lastUsedAt: now.addingTimeInterval(-5_400)),
             Entity(orgId: orgId, kind: .user, id: "user-ana", name: "Ana Silva", email: "ana@acme.dev"),
             Entity(orgId: orgId, kind: .user, id: "user-cy", name: "Cy Park", email: "cy@acme.dev")]
        }
    }

    func fetchLimits(projectIds: [String]) async throws -> [Limit]? {
        guard provider == .openai else { return nil }
        return [Limit(id: "lim_org", orgId: orgId, kind: .hardLimit, thresholdCents: 400_000),
                Limit(id: "lim_org_alert", orgId: orgId, kind: .alert, thresholdCents: 300_000),
                Limit(id: "lim_app", orgId: orgId, projectId: "proj_app", kind: .hardLimit, thresholdCents: 250_000)]
    }
}
