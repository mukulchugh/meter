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
    public static let organizationNote = "Spend data needs an organization account: individual accounts can't read it with any key."

    public static func steps(for provider: Provider) -> String {
        switch provider {
        case .anthropic:
            "Best: an Admin key from platform.claude.com/settings/admin-keys (Create admin key, name it, pick an expiry, Add; it starts with sk-ant-admin and is shown once). Or your own API key, if you're an admin in the Console organization and the key isn't limited to one workspace."
        case .openai:
            "Best: an Admin key from platform.openai.com/settings/organization/admin-keys (it starts with sk-admin-; Organization Owners create them). A regular key works only if it has the Usage: Read permission."
        }
    }

    public static func keyPrefix(for provider: Provider) -> String {
        provider == .anthropic ? "sk-ant-admin" : "sk-admin-"
    }

    /// A key that is certainly for the other provider. Admin keys and personal (user) keys are both
    /// accepted; the provider's answer decides whether the key can read spend.
    public static func wrongKind(_ key: String, for provider: Provider) -> String? {
        switch provider {
        case .anthropic:
            if !key.hasPrefix("sk-ant-") && key.hasPrefix("sk-") {
                return "This looks like an OpenAI key. Switch Provider to OpenAI."
            }
        case .openai:
            if key.hasPrefix("sk-ant-") { return "This is an Anthropic key. Switch Provider to Anthropic." }
        }
        return nil
    }

    /// Whether a key is a regular (user, project or service) key rather than an admin key.
    public static func isUserKey(_ key: String, for provider: Provider) -> Bool {
        switch provider {
        case .anthropic: return key.hasPrefix("sk-ant-") && !key.hasPrefix("sk-ant-admin")
        case .openai: return key.hasPrefix("sk-") && !key.hasPrefix("sk-admin-")
        }
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

    /// A note about what a non-admin key can do. Saving is still allowed; the provider decides.
    public var warning: String? {
        let key = trimmedKey
        guard !key.isEmpty, errors.isEmpty, !key.hasPrefix(ConnectionHelp.keyPrefix(for: provider)) else { return nil }
        if ConnectionHelp.isUserKey(key, for: provider) {
            switch provider {
            case .anthropic:
                return "A user API key works if your account is an admin in the Console organization and the key isn't limited to one workspace. Meter will check."
            case .openai:
                return "OpenAI usually needs an Admin key for organization costs. A key with the Usage: Read permission may work. Meter will check."
            }
        }
        return "\(provider.displayName) keys usually start with \(provider == .anthropic ? "sk-ant-" : "sk-"). Meter will check it with \(provider.displayName)."
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
