import Foundation
import MeterCore

/// "Preview with sample data": a believable company for a CTO to look at before connecting anything.
/// It reuses the demo machinery (a fake provider client run through the real sync engine, an in-memory
/// store, in-memory secrets), so it needs no keys and no network and cannot reach the real store.
///
/// Two Anthropic orgs and one OpenAI org, App and Team tags, eight people with Claude Code activity, a
/// monthly budget at 70%, an OpenAI spend limit, a prepaid balance, a spike on one key, one org with a
/// delayed report and one unavailable breakdown, so every state in the UI shows up.
public enum SampleData {
    public static let productionOrgId = "sample-anthropic-production"
    public static let engineeringOrgId = "sample-anthropic-engineering"
    public static let openAIOrgId = "sample-openai"
    /// The share of the monthly budget the sample has used.
    public static let budgetUsedFraction: Decimal = Decimal(string: "0.7")!

    static let people: [(id: String, name: String, dailyCents: Int)] = [
        ("ana", "Ana Silva", 6_200), ("ben", "Ben Okafor", 4_800), ("dee", "Dee Rao", 3_900), ("eli", "Eli Novak", 3_300),
        ("fay", "Fay Chen", 2_700), ("gus", "Gus Moreau", 2_100), ("hana", "Hana Ito", 1_600), ("ivo", "Ivo Petrov", 900),
    ]
    static func email(_ id: String) -> String { "\(id)@acme.dev" }

    public static func factory(now: Date) -> ProviderClientFactory {
        { org, _ in SampleClient(provider: org.provider, orgId: org.id, now: now) }
    }

    /// Orgs, secrets (fake), synced history, tags, the budget, the OpenAI limit and a prepaid balance.
    public static func seed(store: MeterStore, secrets: any Secrets, engine: SyncEngine, now: Date) async throws {
        let orgs = [
            Org(id: productionOrgId, provider: .anthropic, displayName: "Acme Production"),
            Org(id: engineeringOrgId, provider: .anthropic, displayName: "Acme Engineering"),
            Org(id: openAIOrgId, provider: .openai, displayName: "Acme OpenAI"),
        ]
        for o in orgs {
            try secrets.write("sample-admin-key", for: o.keychainRef)
            try await store.upsertOrg(o)
        }
        _ = await engine.refreshAll()
        try await store.setTag(Tag(orgId: productionOrgId, target: .project, targetId: "ws_prod", kind: .app))
        try await store.setTag(Tag(orgId: engineeringOrgId, target: .project, targetId: "ws_dev", kind: .team))
        try await store.setTag(Tag(orgId: openAIOrgId, target: .project, targetId: "proj_support", kind: .app))
        try await store.setTag(Tag(orgId: openAIOrgId, target: .project, targetId: "proj_research", kind: .team))
        // proj_evals stays untagged on purpose, so the Untagged row and the tagging prompt show.

        // The budget is sized from the spend so far, so it reads 70% whatever day of the month it is.
        let snapshot = try await store.snapshot()
        let spent = snapshot.monthToDate(now: now, filter: .all).amount ?? 0
        let amount = max(wholeDollars(spent / budgetUsedFraction), 100)
        try await store.upsertBudget(Budget(id: "sample-budget", name: "Monthly AI spend", scope: .overall, amount: amount))
        try await store.setPrepaid(PrepaidBalance(orgId: openAIOrgId, amount: 2_500, enteredAt: now.addingTimeInterval(-10 * 86_400)))
    }

    private static func wholeDollars(_ d: Decimal) -> Decimal {
        var v = d, out = Decimal()
        NSDecimalRound(&out, &v, 0, .plain)
        return out
    }
}

/// Deterministic fake provider for the sample company. Amounts come from a hash of the day, in whole cents.
struct SampleClient: ProviderClient {
    let provider: Provider
    let orgId: String
    let now: Date

    var maxCostWindowDays: Int { provider == .anthropic ? 31 : 180 }
    private var today: UTCDay { UTCDay(now) }
    private var isProduction: Bool { orgId == SampleData.productionOrgId }

    private func cents(_ base: Int, _ day: UTCDay, salt: Int, spike: Bool = false) -> Decimal {
        let h = abs((day.daysSinceEpoch &* 2_654_435_761 &+ salt &* 40_503) % 1000)
        var c = base * (800 + h * 4 / 10) / 1000
        let weekday = ((day.daysSinceEpoch + 4) % 7 + 7) % 7
        if weekday == 0 || weekday == 6 { c = c * 6 / 10 }
        if spike && day == today.adding(-3) { c *= 10 }
        return Decimal(c) / 100
    }

    private func line(_ day: UTCDay, _ feed: CostFeed, _ amount: Decimal, model: String? = nil, key: String? = nil,
                      project: String? = nil, actor: String? = nil, item: String? = nil) -> CostLine {
        CostLine(day: day, orgId: orgId, amount: amount, feed: feed, model: model, apiKeyId: key, projectId: project,
                 actor: actor, lineItem: item)
    }

    private func analytics(_ d: UTCDay) -> [CostLine] {
        let f = CostFeed.anthropicAnalytics
        if isProduction {
            return [
                line(d, f, cents(9_500, d, salt: 1, spike: true), model: "claude-opus-5", key: "key_prod", project: "ws_prod"),
                line(d, f, cents(6_500, d, salt: 2), model: "claude-sonnet-5", key: "key_prod", project: "ws_prod"),
                line(d, f, cents(3_800, d, salt: 3), model: "claude-sonnet-5", key: "key_support", project: "ws_prod"),
                line(d, f, cents(1_200, d, salt: 4), model: "claude-haiku-5", key: "key_batch", project: "ws_prod"),
            ]
        }
        var out = [CostLine]()
        for (i, p) in SampleData.people.enumerated() {
            out.append(line(d, f, cents(p.dailyCents, d, salt: 20 + i), model: i % 3 == 0 ? "claude-opus-5" : "claude-sonnet-5",
                            key: "key_\(p.id)", project: "ws_dev", actor: "user_\(p.id)"))
        }
        out.append(line(d, f, cents(1_400, d, salt: 40), model: "claude-haiku-5", key: "key_ci", project: "ws_dev"))
        return out
    }

    private func legacy(_ d: UTCDay) -> [CostLine] {
        let f = CostFeed.anthropicLegacy
        if !isProduction {
            let total = SampleData.people.enumerated().reduce(Decimal(0)) { $0 + cents($1.element.dailyCents, d, salt: 20 + $1.offset) }
            return [line(d, f, total + cents(1_400, d, salt: 40), model: "claude-sonnet-5", project: "ws_dev")]
        }
        return [
            line(d, f, cents(9_500, d, salt: 1, spike: true), model: "claude-opus-5", project: "ws_prod"),
            line(d, f, cents(6_500, d, salt: 2), model: "claude-sonnet-5", project: "ws_prod"),
            line(d, f, cents(5_000, d, salt: 3), model: "claude-sonnet-5", project: "ws_prod"),
        ]
    }

    private func openAI(_ d: UTCDay) -> [CostLine] {
        let f = CostFeed.openaiCosts
        return [
            line(d, f, cents(3_500, d, salt: 6), model: "gpt-6-astra", key: "key_oa_support", project: "proj_support", item: "gpt-6-astra, input tokens"),
            line(d, f, cents(2_800, d, salt: 7), model: "gpt-6-astra", key: "key_oa_support", project: "proj_support", item: "gpt-6-astra, output tokens"),
            line(d, f, cents(1_600, d, salt: 8), model: "gpt-6-mini", key: "key_oa_research", project: "proj_research", item: "gpt-6-mini, input tokens"),
            line(d, f, cents(700, d, salt: 9), model: "gpt-6-mini", key: "key_oa_evals", project: "proj_evals", item: "gpt-6-mini, output tokens"),
        ]
    }

    func fetchCosts(from: UTCDay, to: UTCDay) async throws -> CostFetch {
        let days = UTCDay.range(from: from, through: to)
        switch provider {
        case .anthropic:
            // Production reports 2 hours behind. Engineering reports 7: past the 4 hours Anthropic usually takes, so it reads Delayed.
            let lag: TimeInterval = isProduction ? 2 * 3600 : 7 * 3600
            return CostFetch(lines: days.flatMap(analytics), watermark: now.addingTimeInterval(-lag))
        case .openai: return CostFetch(lines: days.flatMap(openAI))
        }
    }

    func fetchRecentCosts(from: UTCDay, to: UTCDay) async throws -> CostFetch? {
        provider == .anthropic ? CostFetch(lines: UTCDay.range(from: from, through: to).flatMap(legacy)) : nil
    }

    /// The key cannot break OpenAI spend down by person: the one unavailable dimension in the sample.
    func fetchSupplementalCosts(from: UTCDay, to: UTCDay) async throws -> CostFetch? {
        guard provider == .openai else { return nil }
        throw ProviderError.badRequest("this key cannot group costs by user")
    }

    func fetchClaudeCode(day: UTCDay) async throws -> [ClaudeCodeDay]? {
        guard provider == .anthropic, !isProduction else { return nil }
        let w = ((day.daysSinceEpoch + 4) % 7 + 7) % 7
        guard w != 0 && w != 6 else { return [] }
        var out = [ClaudeCodeDay]()
        for (i, p) in SampleData.people.enumerated() {
            let k = 8 - i
            out.append(ClaudeCodeDay(orgId: orgId, day: day, actorType: .user, actorKey: SampleData.email(p.id), sessions: 1 + k / 2,
                                     linesAdded: 40 * k + 20, linesRemoved: 12 * k, commits: k / 3 + 1, pullRequests: k / 4,
                                     estimatedCost: Decimal(p.dailyCents) / 100 * Decimal(string: "0.6")!))
        }
        out.append(ClaudeCodeDay(orgId: orgId, day: day, actorType: .apiKey, actorKey: "ci-review-bot", sessions: 10, linesAdded: 0,
                                 linesRemoved: 0, commits: 0, pullRequests: 0, estimatedCost: 8))
        return out
    }

    func fetchEntities() async throws -> [Entity] {
        switch (provider, isProduction) {
        case (.anthropic, true):
            return [Entity(orgId: orgId, kind: .project, id: "ws_prod", name: "Production"),
                    Entity(orgId: orgId, kind: .apiKey, id: "key_prod", name: "prod-api", parentId: "ws_prod", lastUsedAt: now.addingTimeInterval(-300)),
                    Entity(orgId: orgId, kind: .apiKey, id: "key_support", name: "support-agent", parentId: "ws_prod", lastUsedAt: now.addingTimeInterval(-900)),
                    Entity(orgId: orgId, kind: .apiKey, id: "key_batch", name: "nightly-batch", parentId: "ws_prod", lastUsedAt: now.addingTimeInterval(-14 * 3_600)),
                    Entity(orgId: orgId, kind: .apiKey, id: "key_legacy", name: "legacy-summarizer", parentId: "ws_prod", lastUsedAt: now.addingTimeInterval(-75 * 86_400))]
        case (.anthropic, false):
            var out = [Entity(orgId: orgId, kind: .project, id: "ws_dev", name: "Engineering")]
            for (i, p) in SampleData.people.enumerated() {
                out.append(Entity(orgId: orgId, kind: .user, id: "user_\(p.id)", name: p.name, email: SampleData.email(p.id)))
                out.append(Entity(orgId: orgId, kind: .apiKey, id: "key_\(p.id)", name: "\(p.id)-dev", parentId: "ws_dev",
                                  ownerId: "user_\(p.id)", lastUsedAt: now.addingTimeInterval(-Double(1 + i) * 1_800)))
            }
            out.append(Entity(orgId: orgId, kind: .apiKey, id: "key_ci", name: "ci-evals", parentId: "ws_dev", lastUsedAt: now.addingTimeInterval(-1_200)))
            return out
        default:
            return [Entity(orgId: orgId, kind: .project, id: "proj_support", name: "Support Bot"),
                    Entity(orgId: orgId, kind: .project, id: "proj_research", name: "Research Lab"),
                    Entity(orgId: orgId, kind: .project, id: "proj_evals", name: "Evals"),
                    Entity(orgId: orgId, kind: .apiKey, id: "key_oa_support", name: "support-prod", parentId: "proj_support", lastUsedAt: now.addingTimeInterval(-200)),
                    Entity(orgId: orgId, kind: .apiKey, id: "key_oa_research", name: "research-shared", parentId: "proj_research", lastUsedAt: now.addingTimeInterval(-5_400)),
                    Entity(orgId: orgId, kind: .apiKey, id: "key_oa_evals", name: "evals-runner", parentId: "proj_evals", lastUsedAt: now.addingTimeInterval(-3_600))]
        }
    }

    func fetchLimits(projectIds: [String]) async throws -> [Limit]? {
        guard provider == .openai else { return nil }
        return [Limit(id: "lim_org", orgId: orgId, kind: .hardLimit, thresholdCents: 500_000),
                Limit(id: "lim_org_alert", orgId: orgId, kind: .alert, thresholdCents: 400_000),
                Limit(id: "lim_support", orgId: orgId, projectId: "proj_support", kind: .hardLimit, thresholdCents: 300_000)]
    }
}
