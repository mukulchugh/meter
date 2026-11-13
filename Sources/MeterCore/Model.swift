import Foundation

public enum Provider: String, Sendable, Codable, CaseIterable, Hashable {
    case anthropic
    case openai

    public var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        }
    }
}

/// Where a secret lives. The database stores only this string, never the secret.
public struct KeychainRef: Sendable, Hashable, Codable {
    public static let defaultService = "dev.meter.app"
    public let service: String
    public let account: String

    public init(service: String = KeychainRef.defaultService, account: String) {
        self.service = service
        self.account = account
    }

    /// The reference for an org: service `dev.meter.app`, account = org id.
    public static func forOrg(id: String) -> KeychainRef { KeychainRef(account: id) }

    public var raw: String { "\(service)/\(account)" }

    public init?(raw: String) {
        guard let slash = raw.firstIndex(of: "/") else { return nil }
        self.init(service: String(raw[..<slash]), account: String(raw[raw.index(after: slash)...]))
    }
}

public struct Org: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public var provider: Provider
    public var displayName: String
    public var keychainRef: KeychainRef

    public init(id: String, provider: Provider, displayName: String, keychainRef: KeychainRef? = nil) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.keychainRef = keychainRef ?? .forOrg(id: id)
    }
}

/// Reported = from the provider's cost API. Estimated = computed locally or provider-estimated
/// (for example Claude Code `estimated_cost`). Totals only ever use `reported`.
public enum CostSource: String, Sendable, Codable, Hashable {
    case reported
    case estimated
}

/// Which feed a line came from. Needed so two feeds for the same day are never both summed.
public enum CostFeed: String, Sendable, Codable, Hashable, CaseIterable {
    /// Anthropic `analytics/cost`: complete days only, every dimension.
    case anthropicAnalytics
    /// Anthropic legacy `cost_report`: fresh (about 5 minutes) but workspace and model only.
    case anthropicLegacy
    /// OpenAI `organization/costs` grouped by project, key and line item.
    case openaiCosts
    /// OpenAI `organization/costs` grouped by user only. A second view of the same dollars, so it
    /// never counts toward totals.
    case openaiCostsByUser

    public var isSupplemental: Bool { self == .openaiCostsByUser }

    public var syncSource: SyncSource {
        switch self {
        case .anthropicAnalytics: .anthropicAnalytics
        case .anthropicLegacy: .anthropicLegacy
        case .openaiCosts: .openaiCosts
        case .openaiCostsByUser: .openaiCostsByUser
        }
    }
}

public struct CostLine: Sendable, Hashable {
    public var day: UTCDay
    public var orgId: String
    /// US dollars, exact.
    public var amount: Decimal
    public var currency: String
    public var source: CostSource
    public var feed: CostFeed
    public var model: String?
    public var apiKeyId: String?
    /// Anthropic workspace id or OpenAI project id.
    public var projectId: String?
    /// Anthropic actor id or OpenAI user id. Resolved to a person through `Entity`.
    public var actor: String?
    public var serviceTier: String?
    public var lineItem: String?

    public init(day: UTCDay, orgId: String, amount: Decimal, currency: String = "USD",
                source: CostSource = .reported, feed: CostFeed,
                model: String? = nil, apiKeyId: String? = nil, projectId: String? = nil,
                actor: String? = nil, serviceTier: String? = nil, lineItem: String? = nil) {
        self.day = day
        self.orgId = orgId
        self.amount = amount
        self.currency = currency.uppercased()
        self.source = source
        self.feed = feed
        self.model = model
        self.apiKeyId = apiKeyId
        self.projectId = projectId
        self.actor = actor
        self.serviceTier = serviceTier
        self.lineItem = lineItem
    }

    /// Identity of a line for upserts: everything except the amount.
    struct Key: Hashable {
        let day: UTCDay, orgId: String, feed: CostFeed, source: CostSource
        let model: String, apiKeyId: String, projectId: String, actor: String, serviceTier: String, lineItem: String
        var currency: String
    }
    var key: Key {
        Key(day: day, orgId: orgId, feed: feed, source: source, model: model ?? "", apiKeyId: apiKeyId ?? "",
            projectId: projectId ?? "", actor: actor ?? "", serviceTier: serviceTier ?? "",
            lineItem: lineItem ?? "", currency: currency)
    }

    /// Sums lines that share every dimension (a provider can return several rows for one key).
    public static func mergingDuplicates(_ lines: [CostLine]) -> [CostLine] {
        var order = [Key]()
        var byKey = [Key: CostLine]()
        for l in lines {
            // The unique index has no currency column, so lines that differ only by currency
            // would collide. Providers return USD only; keep the first currency seen per key.
            var k = l.key
            k.currency = ""
            if var existing = byKey[k] {
                if existing.currency == l.currency { existing.amount += l.amount }
                byKey[k] = existing
            } else {
                order.append(k)
                byKey[k] = l
            }
        }
        return order.compactMap { byKey[$0] }
    }
}

public enum EntityKind: String, Sendable, Codable, Hashable {
    case apiKey
    /// Anthropic workspace or OpenAI project.
    case project
    case user
}

/// A name resolved from a list endpoint. Names are cached locally because deleted keys and
/// projects stop resolving (RESEARCH.md section 5).
public struct Entity: Sendable, Hashable {
    public var orgId: String
    public var kind: EntityKind
    public var id: String
    public var name: String
    public var email: String?
    /// For a key, the workspace or project it belongs to.
    public var parentId: String?
    /// For a key, the user that owns it.
    public var ownerId: String?
    public var lastUsedAt: Date?
    public var archived: Bool

    public init(orgId: String, kind: EntityKind, id: String, name: String, email: String? = nil,
                parentId: String? = nil, ownerId: String? = nil, lastUsedAt: Date? = nil, archived: Bool = false) {
        self.orgId = orgId
        self.kind = kind
        self.id = id
        self.name = name
        self.email = email
        self.parentId = parentId
        self.ownerId = ownerId
        self.lastUsedAt = lastUsedAt
        self.archived = archived
    }
}

public enum TagKind: String, Sendable, Codable, Hashable, CaseIterable {
    case app
    case team
    case untagged
}

public enum TagTarget: String, Sendable, Codable, Hashable {
    case apiKey
    case project
}

/// A tag the CTO set on a key or a project/workspace. Suggestions are separate and never applied.
public struct Tag: Sendable, Hashable {
    public var orgId: String
    public var target: TagTarget
    public var targetId: String
    public var kind: TagKind

    public init(orgId: String, target: TagTarget, targetId: String, kind: TagKind) {
        self.orgId = orgId
        self.target = target
        self.targetId = targetId
        self.kind = kind
    }
}

public enum BudgetScope: Sendable, Hashable {
    case overall
    case org(String)
    case tag(TagKind)
    case project(orgId: String, projectId: String)
}

/// A local, alert-only monthly budget. It does not stop spend.
public struct Budget: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var scope: BudgetScope
    /// Monthly amount in US dollars.
    public var amount: Decimal
    /// Percent thresholds that notify. Default 50, 80, 100.
    public var thresholds: [Int]

    public static let defaultThresholds = [50, 80, 100]

    public init(id: String = UUID().uuidString, name: String, scope: BudgetScope, amount: Decimal,
                thresholds: [Int] = Budget.defaultThresholds) {
        self.id = id
        self.name = name
        self.scope = scope
        self.amount = amount
        self.thresholds = thresholds.sorted()
    }
}

/// One person (or API key) for one day, summed across `terminal_type` and similar splits.
/// `estimatedCost` is provider-estimated and is never added to org spend.
public struct ClaudeCodeDay: Sendable, Hashable {
    public enum ActorType: String, Sendable, Codable, Hashable { case user, apiKey }

    public var orgId: String
    public var day: UTCDay
    public var actorType: ActorType
    /// Email address for users, key name for API actors.
    public var actorKey: String
    public var sessions: Int
    public var linesAdded: Int
    public var linesRemoved: Int
    public var commits: Int
    public var pullRequests: Int
    /// US dollars (the API reports cents).
    public var estimatedCost: Decimal

    public init(orgId: String, day: UTCDay, actorType: ActorType, actorKey: String, sessions: Int = 0,
                linesAdded: Int = 0, linesRemoved: Int = 0, commits: Int = 0, pullRequests: Int = 0,
                estimatedCost: Decimal = 0) {
        self.orgId = orgId
        self.day = day
        self.actorType = actorType
        self.actorKey = actorKey
        self.sessions = sessions
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.commits = commits
        self.pullRequests = pullRequests
        self.estimatedCost = estimatedCost
    }
}

/// An OpenAI spend limit or alert (RESEARCH.md section 7). Amounts are integer cents.
public struct Limit: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable, Hashable {
        /// Provider-enforced: requests fail once spend passes it (enforcement can lag).
        case hardLimit
        /// Notification only.
        case alert
    }

    public var id: String
    public var orgId: String
    /// nil for an organization-level limit.
    public var projectId: String?
    public var kind: Kind
    public var thresholdCents: Int
    public var currency: String
    public var interval: String

    public init(id: String, orgId: String, projectId: String? = nil, kind: Kind, thresholdCents: Int,
                currency: String = "USD", interval: String = "month") {
        self.id = id
        self.orgId = orgId
        self.projectId = projectId
        self.kind = kind
        self.thresholdCents = thresholdCents
        self.currency = currency.uppercased()
        self.interval = interval
    }

    public var thresholdUSD: Decimal { Decimal(thresholdCents) / 100 }
}

/// A balance the CTO typed in after a top-up. Always an estimate.
public struct PrepaidBalance: Sendable, Hashable {
    public var orgId: String
    public var amount: Decimal
    public var enteredAt: Date

    public init(orgId: String, amount: Decimal, enteredAt: Date) {
        self.orgId = orgId
        self.amount = amount
        self.enteredAt = enteredAt
    }
}
