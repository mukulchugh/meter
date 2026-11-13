import Foundation
import MeterCore

public struct DimensionRow: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var state: FreshnessState
}

public struct ConnectionRow: Equatable, Identifiable, Sendable {
    public var id: String
    public var org: Org
    public var state: FreshnessState
    public var lastReportText: String
    public var dimensions: [DimensionRow]
    public var errorText: String?
}

public struct ConnectionsContent: Equatable, Sendable {
    public var rows: [ConnectionRow]

    static func dimensionName(_ s: SyncSource) -> String {
        switch s {
        case .anthropicAnalytics: "Spend by key, workspace, model and person"
        case .anthropicLegacy: "Today's spend by workspace and model"
        case .claudeCode: "Claude Code activity"
        case .openaiCosts: "Spend by project, key and model"
        case .openaiCostsByUser: "Spend by person"
        case .entities: "Names of keys, projects and people"
        case .limits: "Spend limits"
        }
    }

    public init(snapshot: MeterSnapshot, now: Date) {
        rows = snapshot.coverageSummary(now: now).orgs.map { c in
            let errors = c.sources.compactMap { $0.lastError }
            return ConnectionRow(
                id: c.org.id, org: c.org, state: c.state,
                lastReportText: Freshness.reportTime(c).map { "Last report \(Fmt.ago($0, now: now))" } ?? "No report yet",
                dimensions: c.sources.map { DimensionRow(id: "\(c.org.id)|\($0.source.rawValue)", name: Self.dimensionName($0.source), state: $0.state) },
                errorText: errors.first)
        }
    }
}

public enum ConnectionHelp {
    public static let organizationNote = "The Admin API requires an organization account. Individual accounts cannot create admin keys."

    public static func steps(for provider: Provider) -> String {
        switch provider {
        case .anthropic:
            "Open the Claude Console at platform.claude.com/settings/admin-keys, choose Create admin key, name it, pick an expiry, then Add. The key starts with sk-ant-admin01- and is shown once. You need the admin role in a Console organization."
        case .openai:
            "Open platform.openai.com/settings/organization/admin-keys and create an admin key. It starts with sk-admin-. Organization owners can create admin keys."
        }
    }

    public static func keyPrefix(for provider: Provider) -> String {
        provider == .anthropic ? "sk-ant-admin01-" : "sk-admin-"
    }
}

/// The add-organization form. The key lives here only until it is written to the secret store.
public struct ConnectionDraft: Equatable, Sendable {
    public var provider: Provider = .anthropic
    public var displayName = ""
    public var adminKey = ""

    public init() {}

    public var trimmedKey: String { adminKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var trimmedName: String { displayName.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var errors: [String] {
        var e = [String]()
        if trimmedName.isEmpty { e.append("Give the organization a name.") }
        if trimmedKey.isEmpty { e.append("Paste an admin key.") }
        else if !trimmedKey.hasPrefix(ConnectionHelp.keyPrefix(for: provider)) {
            e.append("\(provider.displayName) admin keys start with \(ConnectionHelp.keyPrefix(for: provider)).")
        }
        return e
    }
    public var isValid: Bool { errors.isEmpty }
}

/// What happened when a key was saved and the first refresh ran.
public struct ConnectionResult: Equatable, Sendable {
    public var orgId: String
    public var state: FreshnessState
    public var message: String
    public var succeeded: Bool
}
