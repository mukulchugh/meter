import Foundation

/// What a sync step covers. One coverage row per org and source.
public enum SyncSource: String, Sendable, Codable, Hashable, CaseIterable {
    case anthropicAnalytics
    case anthropicLegacy
    case claudeCode
    case openaiCosts
    case openaiCostsByUser
    case entities
    case limits

    /// True for the sources that feed dollar totals.
    var isPrimaryCost: Bool {
        switch self {
        case .anthropicAnalytics, .anthropicLegacy, .openaiCosts: true
        default: false
        }
    }
}

/// State vocabulary from UX-RESEARCH.md section 9, reduced to what the data layer can know.
public enum FreshnessState: String, Sendable, Codable, Hashable, CaseIterable {
    /// Credential saved, nothing fetched yet.
    case connected
    case fresh
    /// Fetch is recent but the provider's reporting watermark lags more than usual.
    case delayed
    /// The last successful fetch is old. The last known value is kept.
    case stale
    /// The latest attempt failed. The last known value, if any, is kept.
    case error
    /// The source cannot provide this breakdown (for example the beta endpoint is unavailable).
    case unavailableDimension
    /// A confirmed, covered interval with nothing spent.
    case noActivity

    /// Worse states sort higher.
    var severity: Int {
        switch self {
        case .fresh, .noActivity: 0
        case .connected: 1
        case .delayed: 2
        case .unavailableDimension: 3
        case .stale: 4
        case .error: 5
        }
    }
    public var needsAttention: Bool { severity >= FreshnessState.delayed.severity }
}

public struct FreshnessPolicy: Sendable {
    /// Fetch older than this means stale.
    public var staleAfter: [SyncSource: TimeInterval]
    /// Watermark lag above this means delayed.
    public var expectedLag: [SyncSource: TimeInterval]
    /// Watermark lag above this means stale.
    public var maxLag: [SyncSource: TimeInterval]

    public static let `default` = FreshnessPolicy(
        staleAfter: [
            .anthropicLegacy: 2 * 3600, .anthropicAnalytics: 3 * 3600, .openaiCosts: 3 * 3600,
            .openaiCostsByUser: 3 * 3600, .claudeCode: 3 * 3600, .limits: 3 * 3600, .entities: 3 * 86_400,
        ],
        // Anthropic analytics "typically refreshes within 4 hours... up to 24 hours"; Claude Code "up to 1 hour"
        // (RESEARCH.md sections 2.1 and 6).
        expectedLag: [.anthropicAnalytics: 4 * 3600, .claudeCode: 3600],
        maxLag: [.anthropicAnalytics: 24 * 3600, .claudeCode: 6 * 3600]
    )

    public init(staleAfter: [SyncSource: TimeInterval], expectedLag: [SyncSource: TimeInterval], maxLag: [SyncSource: TimeInterval]) {
        self.staleAfter = staleAfter
        self.expectedLag = expectedLag
        self.maxLag = maxLag
    }
}

/// Freshness and coverage for one org and one source. Two timestamps, as UX-RESEARCH.md section 1
/// asks: when Meter last fetched, and how far the provider's data runs.
public struct Coverage: Sendable, Hashable {
    public var orgId: String
    public var source: SyncSource
    public var lastAttempt: Date?
    /// "Fetched": when Meter last succeeded.
    public var lastSuccess: Date?
    /// "Data through": the provider's `data_refreshed_at` or other reporting watermark. nil means the
    /// provider gives none, so coverage is unknown rather than implied fresh.
    public var watermark: Date?
    /// The first UTC day of the unbroken span this source has stored lines for. nil means "from the
    /// beginning" (only hand-built coverage leaves it unset; sync always sets it). Days before it are not covered.
    public var coveredFrom: UTCDay?
    /// The last UTC day this source has stored lines for. Days after it are not covered.
    public var coveredThrough: UTCDay?
    public var lastError: String?
    public var errorKind: String?
    /// The last successful fetch returned nothing for its whole window.
    public var lastFetchEmpty: Bool
    /// The source cannot provide its data (kept apart from errors).
    public var unavailable: Bool
    public var note: String?

    public init(orgId: String, source: SyncSource, lastAttempt: Date? = nil, lastSuccess: Date? = nil,
                watermark: Date? = nil, coveredFrom: UTCDay? = nil, coveredThrough: UTCDay? = nil, lastError: String? = nil,
                errorKind: String? = nil, lastFetchEmpty: Bool = false, unavailable: Bool = false, note: String? = nil) {
        self.orgId = orgId
        self.source = source
        self.lastAttempt = lastAttempt
        self.lastSuccess = lastSuccess
        self.watermark = watermark
        self.coveredFrom = coveredFrom
        self.coveredThrough = coveredThrough
        self.lastError = lastError
        self.errorKind = errorKind
        self.lastFetchEmpty = lastFetchEmpty
        self.unavailable = unavailable
        self.note = note
    }

    /// Whether a last known value exists to keep showing next to an error.
    public var hasLastKnownValue: Bool { lastSuccess != nil }

    public func state(now: Date, policy: FreshnessPolicy = .default) -> FreshnessState {
        if unavailable { return .unavailableDimension }
        if lastError != nil { return .error }
        guard let success = lastSuccess else { return .connected }
        if let limit = policy.staleAfter[source], now.timeIntervalSince(success) > limit { return .stale }
        if let mark = watermark {
            let lag = now.timeIntervalSince(mark)
            if let max = policy.maxLag[source], lag > max { return .stale }
            if let expected = policy.expectedLag[source], lag > expected { return .delayed }
        }
        return lastFetchEmpty ? .noActivity : .fresh
    }
}
