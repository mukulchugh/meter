import Foundation
import MeterCore

public struct PersonRow: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var email: String
    public var anthropic: Decimal?
    public var openai: Decimal?
    public var total: Decimal?
    /// Claude Code activity. Its cost is provider-estimated and never part of `total`.
    public var activity: ClaudeCodePerson?

    public var anthropicText: String { anthropic.map(Fmt.usd) ?? "None" }
    public var openaiText: String { openai.map(Fmt.usd) ?? "None" }
    public var totalText: String { total.map(Fmt.usd) ?? "None" }
    public var sessionsText: String { activity.map { Fmt.count($0.sessions) } ?? "None" }
    public var linesText: String { activity.map { "+\(Fmt.count($0.linesAdded)) / -\(Fmt.count($0.linesRemoved))" } ?? "None" }
    public var commitsText: String { activity.map { Fmt.count($0.commits) } ?? "None" }
    public var pullRequestsText: String { activity.map { Fmt.count($0.pullRequests) } ?? "None" }
    public var estimatedCostText: String { activity.map { Fmt.usd($0.estimatedCost) } ?? "None" }
}

public struct UnmatchedRow: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var orgName: String
    public var amountText: String
    public var reason: String
}

public struct PeopleContent: Equatable, Sendable {
    public static let estimateColumnTitle = "Claude Code cost (estimate)"
    public var rows: [PersonRow]
    public var unmatched: [UnmatchedRow]
    /// Claude Code activity from API keys rather than people.
    public var apiActors: [ClaudeCodePerson]
    public var periodText: String

    public init(snapshot: MeterSnapshot, now: Date, scope: Scope) {
        let day = UTCDay(now)
        let from = day.monthStart
        let filter = scope.filter
        periodText = "\(Fmt.shortDay(from)) to \(Fmt.shortDay(day)), UTC"

        let result = snapshot.people(from: from, to: day, filter: filter)
        let activity = snapshot.claudeCodeActivity(from: from, to: day, filter: filter)
        let byEmail = Dictionary(activity.filter { $0.actorType == .user }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var out = result.people.map { p in
            PersonRow(id: p.email, name: p.displayName, email: p.email, anthropic: p.byProvider[.anthropic],
                      openai: p.byProvider[.openai], total: p.total, activity: byEmail[p.email])
        }
        let known = Set(out.map(\.email))
        for (email, a) in byEmail where !known.contains(email) {
            out.append(PersonRow(id: email, name: email, email: email, anthropic: nil, openai: nil, total: nil, activity: a))
        }
        rows = out.sorted {
            switch ($0.total, $1.total) {
            case let (a?, b?) where a != b: return a > b
            case (nil, _?): return false
            case (_?, nil): return true
            default: return $0.email < $1.email
            }
        }
        unmatched = result.unmatched.map {
            UnmatchedRow(id: "\($0.orgId)|\($0.actorId)", name: $0.name ?? $0.actorId,
                         orgName: snapshot.org($0.orgId)?.displayName ?? $0.orgId, amountText: Fmt.usd($0.amount),
                         reason: Self.reasonText($0.reason))
        }
        apiActors = activity.filter { $0.actorType == .apiKey }
    }

    static func reasonText(_ r: UnmatchedActor.Reason) -> String {
        switch r {
        case .noUserRecord: "No user record for this id"
        case .noEmail: "User has no email"
        case .nonUserActor: "An API key, not a person"
        }
    }
}
