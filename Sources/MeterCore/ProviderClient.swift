import Foundation

public struct CostFetch: Sendable, Equatable {
    public var lines: [CostLine]
    /// Provider reporting watermark (Anthropic `data_refreshed_at`). nil when the provider gives none.
    public var watermark: Date?

    public init(lines: [CostLine], watermark: Date? = nil) {
        self.lines = lines
        self.watermark = watermark
    }
}

/// A provider client bound to one org and one secret. Everything the sync engine needs, so tests can
/// swap it or, better, swap the `HTTPTransport` underneath the real clients.
public protocol ProviderClient: Sendable {
    var provider: Provider { get }
    /// Longest span one `fetchCosts` call may cover (Anthropic analytics 31 days, OpenAI 180 buckets).
    var maxCostWindowDays: Int { get }
    /// Primary cost feed for `[from, to]`, at most `maxCostWindowDays` days.
    func fetchCosts(from: UTCDay, to: UTCDay) async throws -> CostFetch
    /// A fresher but coarser feed for the newest days (Anthropic legacy `cost_report`). nil if none.
    func fetchRecentCosts(from: UTCDay, to: UTCDay) async throws -> CostFetch?
    /// A per-user view of the same dollars, for providers that cannot combine it with other dimensions.
    func fetchSupplementalCosts(from: UTCDay, to: UTCDay) async throws -> CostFetch?
    /// Claude Code activity for one day. nil if the provider has none.
    func fetchClaudeCode(day: UTCDay) async throws -> [ClaudeCodeDay]?
    func fetchEntities() async throws -> [Entity]
    /// Spend limits and alerts. nil if the provider exposes none (Anthropic: console only).
    func fetchLimits(projectIds: [String]) async throws -> [Limit]?
}

public extension ProviderClient {
    func fetchRecentCosts(from: UTCDay, to: UTCDay) async throws -> CostFetch? { nil }
    func fetchSupplementalCosts(from: UTCDay, to: UTCDay) async throws -> CostFetch? { nil }
    func fetchClaudeCode(day: UTCDay) async throws -> [ClaudeCodeDay]? { nil }
    func fetchLimits(projectIds: [String]) async throws -> [Limit]? { nil }
}

/// Builds a client for an org from its secret. The sync engine takes one so tests can inject a
/// transport.
public typealias ProviderClientFactory = @Sendable (_ org: Org, _ secret: String) -> any ProviderClient

public func defaultClientFactory(transport: any HTTPTransport = URLSessionTransport()) -> ProviderClientFactory {
    { org, secret in
        switch org.provider {
        case .anthropic: AnthropicClient(orgId: org.id, apiKey: secret, transport: transport)
        case .openai: OpenAIClient(orgId: org.id, apiKey: secret, transport: transport)
        }
    }
}
