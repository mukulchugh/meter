import Foundation
import MeterCore

public struct KeyRow: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable { case key, project }
    public var id: String
    public var orgId: String
    public var orgName: String
    public var provider: Provider
    public var kind: Kind
    public var targetId: String
    public var name: String
    /// The tag set on this key or project itself.
    public var tag: TagKind
    public var month: Decimal?
    public var today: Decimal?
    public var lastUsed: Date?
    public var owner: String?
    public var isUnused: Bool
    public var isRunaway: Bool

    public var kindText: String {
        switch (kind, provider) {
        case (.key, _): "Key"
        case (.project, .anthropic): "Workspace"
        case (.project, .openai): "Project"
        }
    }
    public var tagTarget: TagTarget { kind == .key ? .apiKey : .project }
    public var monthText: String { Fmt.usd(month) }
    public var todayText: String { Fmt.usd(today) }
    public func lastUsedText(now: Date) -> String { lastUsed.map { Fmt.ago($0, now: now) } ?? "Never seen" }
    public var ownerText: String { owner ?? "Not set" }
    public var flagText: String? {
        if isRunaway { return "Runaway" }
        if isUnused { return "Unused 30 days" }
        return nil
    }
}

public struct SuggestionRow: Equatable, Identifiable, Sendable {
    public var id: String
    public var orgName: String
    public var name: String
    public var suggested: TagKind
    public var reason: String
    public var suggestion: TagSuggestion
}

public struct KeysContent: Equatable, Sendable {
    public var rows: [KeyRow]
    public var suggestions: [SuggestionRow]

    public static func suggestionId(_ s: TagSuggestion) -> String { "\(s.orgId)|\(s.target.rawValue)|\(s.targetId)" }

    public init(snapshot: MeterSnapshot, now: Date, scope: Scope, dismissed: Set<String> = []) {
        let filter = scope.filter
        let today = UTCDay(now)
        func spend(_ dim: DriverDimension, _ from: UTCDay, _ to: UTCDay) -> [String: Decimal] {
            var out = [String: Decimal]()
            for d in snapshot.topDrivers(dim, limit: Int.max, from: from, to: to, filter: filter) {
                if let org = d.orgId, let id = d.id { out["\(org)|\(id)"] = d.amount }
            }
            return out
        }
        let month: [DriverDimension: [String: Decimal]] = [
            .apiKey: spend(.apiKey, today.monthStart, today), .project: spend(.project, today.monthStart, today)]
        let day: [DriverDimension: [String: Decimal]] = [
            .apiKey: spend(.apiKey, today, today), .project: spend(.project, today, today)]
        let recentKeys = spend(.apiKey, today.adding(-1), today)
        let baseKeys = spend(.apiKey, today.adding(-15), today.adding(-2))
        let last30: [DriverDimension: [String: Decimal]] = [
            .apiKey: spend(.apiKey, today.adding(-29), today), .project: spend(.project, today.adding(-29), today)]

        let coverage = Dictionary(uniqueKeysWithValues: snapshot.coverageSummary(now: now).orgs.map { ($0.org.id, $0) })
        let tags = Dictionary(snapshot.tags.map { ("\($0.orgId)|\($0.target.rawValue)|\($0.targetId)", $0.kind) },
                              uniquingKeysWith: { a, _ in a })

        var out = [KeyRow]()
        for e in snapshot.entities where (e.kind == .apiKey || e.kind == .project) {
            if let ids = filter.orgIds, !ids.contains(e.orgId) { continue }
            guard let org = snapshot.org(e.orgId) else { continue }
            let isKey = e.kind == .apiKey
            let dim: DriverDimension = isKey ? .apiKey : .project
            let key = "\(e.orgId)|\(e.id)"
            let hasData = coverage[e.orgId]?.coveredThrough != nil
            let m = month[dim]?[key]
            // Archived entries only matter while they still carry spend.
            if e.archived && m == nil && (last30[dim]?[key] == nil) { continue }

            var runaway = false
            if isKey {
                let r = (recentKeys[key] ?? 0) / 2, b = (baseKeys[key] ?? 0) / 14
                runaway = b > 0 && r > b * 2
            } else {
                runaway = !snapshot.spikes(now: now, lookbackDays: 3, filter: CostFilter(orgIds: [e.orgId], project: ProjectRef(orgId: e.orgId, projectId: e.id))).isEmpty
            }
            let unused = hasData && !e.archived && last30[dim]?[key] == nil
            // Anthropic reports a key only once its day closes, so today has no per-key figure.
            let todayValue: Decimal? = (isKey && org.provider == .anthropic) ? nil : (hasData ? (day[dim]?[key] ?? 0) : nil)
            out.append(KeyRow(
                id: "\(e.orgId)|\(isKey ? "key" : "project")|\(e.id)", orgId: e.orgId, orgName: org.displayName,
                provider: org.provider, kind: isKey ? .key : .project, targetId: e.id, name: e.name,
                tag: tags["\(e.orgId)|\(isKey ? "apiKey" : "project")|\(e.id)"] ?? .untagged,
                month: m ?? (hasData ? 0 : nil), today: todayValue, lastUsed: e.lastUsedAt,
                owner: e.ownerId.flatMap { snapshot.entity(orgId: e.orgId, kind: .user, id: $0)?.name },
                isUnused: unused, isRunaway: runaway))
        }
        rows = out.sorted {
            let a = $0.month ?? -1, b = $1.month ?? -1
            return a != b ? a > b : ($0.orgName, $0.name) < ($1.orgName, $1.name)
        }
        suggestions = snapshot.tagSuggestions().filter { s in
            !dismissed.contains(Self.suggestionId(s)) && (filter.orgIds?.contains(s.orgId) ?? true)
        }.map {
            SuggestionRow(id: Self.suggestionId($0), orgName: snapshot.org($0.orgId)?.displayName ?? $0.orgId, name: $0.name,
                          suggested: $0.suggested, reason: $0.reason, suggestion: $0)
        }
    }
}

public struct ModelRow: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var amount: Decimal
    public var share: Double
    public var amountText: String { Fmt.usd(amount) }
    public var shareText: String { Fmt.percent(share * 100) }
    public var isUnattributed: Bool
}

public struct ModelsContent: Equatable, Sendable {
    public var rows: [ModelRow]
    public var periodText: String
    /// MeterCore stores cost only, so token counts are not available.
    public static let tokensNote = "Token counts are not available yet. Spend only."

    public init(snapshot: MeterSnapshot, now: Date, scope: Scope) {
        let today = UTCDay(now)
        periodText = "\(Fmt.shortDay(today.monthStart)) to \(Fmt.shortDay(today)), UTC"
        rows = snapshot.topDrivers(.model, limit: Int.max, from: today.monthStart, to: today, filter: scope.filter).enumerated().map { i, d in
            ModelRow(id: "\(i)-\(d.name)", name: d.name, amount: d.amount, share: d.share ?? 0, isUnattributed: d.isUnattributed)
        }
    }
}
