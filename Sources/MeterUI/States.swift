import Foundation
import MeterCore

public enum Tone: Sendable, Equatable { case good, neutral, caution, bad, muted }

/// The plain-language description of each freshness state (UX-RESEARCH section 9). One exhaustive switch,
/// so a new core state fails to compile until it has copy.
public struct StateInfo: Sendable, Equatable {
    public let label: String
    public let detail: String
    public let symbol: String
    public let tone: Tone

    public static func of(_ state: FreshnessState) -> StateInfo {
        switch state {
        case .connected:
            StateInfo(label: "Connected", detail: "Key saved. Waiting for the first report.", symbol: "link", tone: .neutral)
        case .fresh:
            StateInfo(label: "Fresh", detail: "Up to date with the provider.", symbol: "checkmark.circle", tone: .good)
        case .delayed:
            StateInfo(label: "Delayed", detail: "The provider's report is running behind. Numbers are correct up to its last report.", symbol: "clock", tone: .caution)
        case .stale:
            StateInfo(label: "Stale", detail: "No successful fetch for a while. Showing the last known values.", symbol: "clock.badge.exclamationmark", tone: .bad)
        case .error:
            StateInfo(label: "Error", detail: "The last fetch failed. Showing the last known values.", symbol: "exclamationmark.triangle", tone: .bad)
        case .unavailableDimension:
            StateInfo(label: "Not available", detail: "This key cannot provide this breakdown.", symbol: "minus.circle", tone: .muted)
        case .noActivity:
            StateInfo(label: "No activity", detail: "Covered, and nothing was spent.", symbol: "moon.zzz", tone: .neutral)
        }
    }
}

/// Short per-org freshness text for the popover rows.
public enum Freshness {
    /// "reported 3h ago", "delayed", "key invalid", and so on.
    public static func text(for org: OrgCoverage, snapshot: MeterSnapshot, now: Date) -> String {
        switch org.state {
        case .error:
            let kinds = snapshot.coverage.filter { $0.orgId == org.org.id && $0.lastError != nil }
            if kinds.contains(where: { $0.errorKind == "auth" }) {
                return org.org.credential == .apiKey ? "key invalid" : "sign-in needed"
            }
            return "error, showing last value"
        case .stale: return "stale" + reportedSuffix(org, now: now)
        case .delayed: return "delayed" + reportedSuffix(org, now: now)
        case .connected: return "waiting for first report"
        case .unavailableDimension: return "some breakdowns unavailable"
        case .noActivity: return "no activity" + reportedSuffix(org, now: now)
        case .fresh:
            if let t = reportTime(org) { return "reported \(Fmt.ago(t, now: now))" }
            return "reported"
        }
    }

    private static func reportedSuffix(_ org: OrgCoverage, now: Date) -> String {
        reportTime(org).map { ", reported \(Fmt.ago($0, now: now))" } ?? ""
    }

    /// The time of the org's latest provider report: the watermark when the provider gives one,
    /// otherwise the last successful fetch of a dollar feed.
    public static func reportTime(_ org: OrgCoverage) -> Date? {
        let dollar = org.sources.filter { $0.source == .anthropicAnalytics || $0.source == .anthropicLegacy || $0.source == .openaiCosts }
        return dollar.compactMap { $0.watermark ?? $0.lastSuccess }.max()
    }
}
