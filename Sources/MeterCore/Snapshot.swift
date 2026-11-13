import Foundation

public struct ProjectRef: Sendable, Hashable {
    public var orgId: String
    public var projectId: String
    public init(orgId: String, projectId: String) {
        self.orgId = orgId
        self.projectId = projectId
    }
}

/// Narrows a query. Fields combine with AND.
public struct CostFilter: Sendable, Equatable {
    public var orgIds: Set<String>?
    public var provider: Provider?
    public var tag: TagKind?
    public var project: ProjectRef?

    public init(orgIds: Set<String>? = nil, provider: Provider? = nil, tag: TagKind? = nil, project: ProjectRef? = nil) {
        self.orgIds = orgIds
        self.provider = provider
        self.tag = tag
        self.project = project
    }

    public static let all = CostFilter()
}

/// An immutable copy of everything stored. All query functions live in extensions and take `now`
/// explicitly, so they are pure and testable without a database.
public struct MeterSnapshot: Sendable {
    public let orgs: [Org]
    public let lines: [CostLine]
    public let entities: [Entity]
    public let tags: [Tag]
    public let budgets: [Budget]
    public let claudeCode: [ClaudeCodeDay]
    public let limits: [Limit]
    public let prepaid: [PrepaidBalance]
    public let coverage: [Coverage]

    struct EntityKey: Hashable { let orgId: String; let kind: EntityKind; let id: String }
    struct TagKey: Hashable { let orgId: String; let target: TagTarget; let id: String }

    let orgsById: [String: Org]
    let entityIndex: [EntityKey: Entity]
    let tagIndex: [TagKey: TagKind]

    public init(orgs: [Org] = [], lines: [CostLine] = [], entities: [Entity] = [], tags: [Tag] = [],
                budgets: [Budget] = [], claudeCode: [ClaudeCodeDay] = [], limits: [Limit] = [],
                prepaid: [PrepaidBalance] = [], coverage: [Coverage] = []) {
        self.orgs = orgs
        self.lines = lines
        self.entities = entities
        self.tags = tags
        self.budgets = budgets
        self.claudeCode = claudeCode
        self.limits = limits
        self.prepaid = prepaid
        self.coverage = coverage
        orgsById = Dictionary(orgs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        entityIndex = Dictionary(entities.map { (EntityKey(orgId: $0.orgId, kind: $0.kind, id: $0.id), $0) }, uniquingKeysWith: { a, _ in a })
        tagIndex = Dictionary(tags.filter { $0.kind != .untagged }.map { (TagKey(orgId: $0.orgId, target: $0.target, id: $0.targetId), $0.kind) },
                              uniquingKeysWith: { a, _ in a })
    }

    // MARK: Lookups

    public func org(_ id: String) -> Org? { orgsById[id] }
    public func entity(orgId: String, kind: EntityKind, id: String) -> Entity? { entityIndex[EntityKey(orgId: orgId, kind: kind, id: id)] }

    /// A key's tag wins over its project's tag; neither set means untagged.
    public func tag(for line: CostLine) -> TagKind {
        tag(orgId: line.orgId, apiKeyId: line.apiKeyId, projectId: line.projectId)
    }

    public func tag(orgId: String, apiKeyId: String?, projectId: String?) -> TagKind {
        if let k = apiKeyId, let t = tagIndex[TagKey(orgId: orgId, target: .apiKey, id: k)] { return t }
        if let p = projectId, let t = tagIndex[TagKey(orgId: orgId, target: .project, id: p)] { return t }
        return .untagged
    }

    func scopedOrgs(_ f: CostFilter) -> [Org] {
        orgs.filter { o in
            (f.orgIds?.contains(o.id) ?? true) && (f.provider.map { $0 == o.provider } ?? true)
                && (f.project.map { $0.orgId == o.id } ?? true)
        }
    }

    func matches(_ l: CostLine, _ f: CostFilter) -> Bool {
        if let ids = f.orgIds, !ids.contains(l.orgId) { return false }
        if let p = f.provider, orgsById[l.orgId]?.provider != p { return false }
        if let proj = f.project, !(proj.orgId == l.orgId && proj.projectId == l.projectId) { return false }
        if let t = f.tag, tag(for: l) != t { return false }
        return true
    }

    /// Provider-reported dollars that count toward totals: reported only, USD only, no supplemental feed.
    func reportedLines(from: UTCDay, to: UTCDay, filter: CostFilter) -> [CostLine] {
        lines.filter {
            $0.source == .reported && !$0.feed.isSupplemental && $0.currency == "USD"
                && $0.day >= from && $0.day <= to && matches($0, filter)
        }
    }

    func sum(_ lines: [CostLine]) -> Decimal { lines.reduce(0) { $0 + $1.amount } }

    /// Unbroken day spans the org's dollar feeds cover, merged where feeds abut or overlap, oldest first.
    /// Coverage is a set of spans, not a high-water mark: a feed that stopped midway or a skipped window
    /// leaves a gap, and a total over a gap is partial.
    func coverageSpans(orgId: String) -> [(from: UTCDay, through: UTCDay)] {
        let spans = coverage.filter { $0.orgId == orgId && $0.source.isPrimaryCost }.compactMap { c -> (UTCDay, UTCDay)? in
            guard let through = c.coveredThrough else { return nil }
            return (c.coveredFrom ?? UTCDay(daysSinceEpoch: Int.min / 2), through)
        }.sorted { $0.0 < $1.0 }
        var merged = [(from: UTCDay, through: UTCDay)]()
        for s in spans {
            if let last = merged.last, s.0 <= last.through.adding(1) {
                merged[merged.count - 1].through = max(last.through, s.1)
            } else {
                merged.append((s.0, s.1))
            }
        }
        return merged
    }

    /// The last UTC day any dollar feed for this org has stored data through.
    func coveredThrough(orgId: String) -> UTCDay? {
        coverage.filter { $0.orgId == orgId && $0.source.isPrimaryCost }.compactMap(\.coveredThrough).max()
    }
}
