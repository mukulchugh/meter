import Foundation

/// Plan usage: how much of a subscription allowance is used. A different product from API spend
/// (UX-RESEARCH section 1): no dollars, never summed with spend, never read by a spend query. It is not
/// part of `MeterSnapshot`.
public enum PlanProvider: String, Sendable, Codable, CaseIterable, Hashable {
    case claude
    case chatgpt

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .chatgpt: "Codex"
        }
    }
}

public struct PlanWindow: Sendable, Hashable, Codable {
    /// "5-hour", "weekly", ...
    public var name: String
    public var windowMinutes: Int?
    /// 0 to 100 (can exceed 100).
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(name: String, windowMinutes: Int? = nil, usedPercent: Double, resetsAt: Date? = nil) {
        self.name = name
        self.windowMinutes = windowMinutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    /// A name from the window length, never from its position ("primary" is not always 5 hours).
    public static func name(forMinutes m: Int?) -> String {
        guard let m, m > 0 else { return "limit" }
        if m == 10_080 { return "weekly" }
        if m % 1440 == 0 { return "\(m / 1440)-day" }
        if m % 60 == 0 { return "\(m / 60)-hour" }
        return "\(m)-minute"
    }
}

public enum PlanUsageState: String, Sendable, Codable, Hashable {
    // Stored states
    case ok
    case notInstalled
    case notLoggedIn
    /// Signed in with an API key (or another non-ChatGPT account): there are no plan limits to show.
    case noPlanLimits
    /// Claude Code: Meter's status line hook is not on.
    case notEnabled
    /// Claude Code: the hook is on but no session has reported yet.
    case waiting
    case error
    // Derived from age and the windows (see `PlanUsage.effectiveState`)
    case stale
    case limitReached
    /// Every window's reset time has passed and no fresh reading confirms the new allowance.
    case resetPending
}

public struct PlanUsage: Sendable, Equatable, Codable {
    public var provider: PlanProvider
    public var planName: String?
    public var windows: [PlanWindow]
    public var fetchedAt: Date
    public var state: PlanUsageState
    public var detail: String?

    public init(provider: PlanProvider, planName: String? = nil, windows: [PlanWindow] = [], fetchedAt: Date,
                state: PlanUsageState, detail: String? = nil) {
        self.provider = provider
        self.planName = planName
        self.windows = windows
        self.fetchedAt = fetchedAt
        self.state = state
        self.detail = detail
    }

    /// A reading older than this is shown as stale. Claude Code only reports while it is in use.
    public static let staleAfter: TimeInterval = 3600

    /// What to show now: the stored state, refined by age and by the windows' reset times.
    public func effectiveState(now: Date) -> PlanUsageState {
        guard state == .ok else { return state }
        if now.timeIntervalSince(fetchedAt) > Self.staleAfter { return .stale }
        let live = windows.filter { w in w.resetsAt.map { $0 > now } ?? true }
        if !windows.isEmpty && live.isEmpty { return .resetPending }
        if live.contains(where: { $0.usedPercent >= 100 }) { return .limitReached }
        return .ok
    }
}
