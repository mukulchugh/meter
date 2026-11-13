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
        provider == .anthropic ? "sk-ant-admin" : "sk-admin-"
    }

    /// A key that is certainly not an admin key for this provider, with what to do instead.
    public static func wrongKind(_ key: String, for provider: Provider) -> String? {
        switch provider {
        case .anthropic:
            if key.hasPrefix("sk-ant-api") || key.hasPrefix("sk-ant-oat") {
                return "This is a regular Anthropic API key. Meter needs an Admin key: create one at platform.claude.com/settings/admin-keys (it starts with sk-ant-admin)."
            }
            if !key.hasPrefix("sk-ant-") && key.hasPrefix("sk-") {
                return "This looks like an OpenAI key. Switch Provider to OpenAI, or paste an Anthropic Admin key."
            }
        case .openai:
            if key.hasPrefix("sk-ant-") { return "This is an Anthropic key. Switch Provider to Anthropic." }
            if key.hasPrefix("sk-proj-") || key.hasPrefix("sk-svcacct-") || (key.hasPrefix("sk-") && !key.hasPrefix("sk-admin-") && key.count > 40 && !key.contains("admin")) {
                return "This is a regular OpenAI API key. Meter needs an Admin key: an Org Owner creates one under Settings, Organization, Admin keys (it starts with sk-admin-)."
            }
        }
        return nil
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

    /// The name shown in Meter: what the user typed, or the provider's name.
    public var effectiveName: String { trimmedName.isEmpty ? provider.displayName : trimmedName }

    /// Problems that block saving. Only keys that are certainly the wrong kind are refused; the provider's
    /// own answer judges everything else (a new admin-key prefix must not lock anyone out).
    public var errors: [String] {
        let key = trimmedKey
        if key.isEmpty { return ["Paste an admin key."] }
        if let wrong = ConnectionHelp.wrongKind(key, for: provider) { return [wrong] }
        return []
    }

    /// A gentle note when the key doesn't look like the usual admin key. Saving is still allowed.
    public var warning: String? {
        let key = trimmedKey
        guard !key.isEmpty, errors.isEmpty, !key.hasPrefix(ConnectionHelp.keyPrefix(for: provider)) else { return nil }
        return "\(provider.displayName) admin keys usually start with \(ConnectionHelp.keyPrefix(for: provider)). Meter will check it with \(provider.displayName)."
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
