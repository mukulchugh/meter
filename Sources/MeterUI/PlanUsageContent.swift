import Foundation
import MeterCore

/// Display text for plan usage. Plan usage is "your plan, not API spend": percentages and reset times
/// only, never a dollar amount, never added to spend.
public enum PlanLabel {
    public static let basis = "Your plan, not API spend"
    public static let sectionTitle = "Plan usage"
}

public struct PlanWindowRow: Equatable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var short: String
    public var fraction: Double
    public var percentText: String
    public var resetText: String?
    public var exceeded: Bool
}

public struct PlanRow: Equatable, Identifiable, Sendable {
    public var id: String { provider.rawValue }
    public var provider: PlanProvider
    public var title: String
    public var state: PlanUsageState
    public var stateLabel: String
    public var stateDetail: String
    public var windows: [PlanWindowRow]
    public var updatedText: String?
    /// "Claude plan: 5h 42%, resets 3:10 PM; weekly 18%", or the state in words.
    public var summary: String
    /// Whether the popover should show this row (nothing to say for a tool that is not set up).
    public var showInPopover: Bool
}

public struct PlanUsageContent: Equatable, Sendable {
    public var rows: [PlanRow]

    public var popoverRows: [PlanRow] { rows.filter(\.showInPopover) }

    public init(plans: [PlanUsage], now: Date, timeZone: TimeZone = .current) {
        rows = PlanProvider.allCases.map { p in
            Self.row(plans.first { $0.provider == p } ?? PlanUsage(provider: p, fetchedAt: now, state: p == .claude ? .notEnabled : .notInstalled),
                     known: plans.contains { $0.provider == p }, now: now, timeZone: timeZone)
        }
    }

    static func short(_ name: String) -> String { name == "5-hour" ? "5h" : name }

    static func row(_ u: PlanUsage, known: Bool, now: Date, timeZone: TimeZone) -> PlanRow {
        let state = known ? u.effectiveState(now: now) : u.state
        let info = stateInfo(state, provider: u.provider)
        let windows = u.windows.map { w in
            PlanWindowRow(name: w.name, short: short(w.name), fraction: max(0, min(1, w.usedPercent / 100)),
                          percentText: Fmt.percent(w.usedPercent),
                          resetText: w.resetsAt.map { resetText($0, now: now, timeZone: timeZone) },
                          exceeded: w.usedPercent >= 100)
        }
        let shows = state != .notEnabled && state != .notInstalled && known
        let name = u.planName ?? (u.provider == .claude ? "Claude plan" : "Codex plan")
        var summary: String
        switch state {
        case .ok, .stale, .limitReached, .resetPending:
            let parts = windows.map { w in "\(w.short) \(w.percentText)" + (w.resetText.map { ", resets \($0)" } ?? "") }
            summary = "\(name): " + parts.joined(separator: "; ")
            if state == .stale { summary += " (\(info.label.lowercased()), \(Fmt.ago(u.fetchedAt, now: now)))" }
            if state == .limitReached { summary += " (limit reached)" }
            if state == .resetPending { summary += " (reset pending)" }
        default:
            summary = "\(u.provider.displayName): \(info.label.lowercased())"
        }
        return PlanRow(provider: u.provider, title: u.provider.displayName, state: state, stateLabel: info.label,
                       stateDetail: u.detail ?? info.detail, windows: windows,
                       updatedText: windows.isEmpty ? nil : "Updated \(Fmt.ago(u.fetchedAt, now: now))",
                       summary: summary, showInPopover: shows)
    }

    /// "3:10 PM" for today, "Mon 3:10 PM" otherwise, in the given time zone.
    static func resetText(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        if date <= now { return "now" }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = timeZone
        f.dateFormat = cal.isDate(date, inSameDayAs: now) ? "h:mm a" : "EEE h:mm a"
        return f.string(from: date)
    }

    /// Copy for each state (UX-RESEARCH section 9), per tool where the wording differs.
    static func stateInfo(_ s: PlanUsageState, provider: PlanProvider) -> (label: String, detail: String) {
        switch s {
        case .ok: ("Current", "Read from your plan.")
        case .notInstalled: ("Not installed", "Codex is not installed on this Mac.")
        case .notLoggedIn: ("Disconnected", "Codex is not signed in. Run codex login in a terminal, then refresh.")
        case .noPlanLimits: ("No plan limits", "Codex is signed in with an API key, which has no plan limits.")
        case .notEnabled: ("Not enabled", "Turn on the Claude Code hook to read your Claude plan limits.")
        case .waiting: ("Waiting for first report", "Meter's hook is on. Limits appear after your next Claude Code message.")
        case .error: ("Error", "The last read failed. Showing the last known values.")
        case .stale:
            ("Stale", provider == .claude ? "Claude Code reports only while it is in use. Showing the last reading."
                                           : "No recent reading. Showing the last one.")
        case .limitReached: ("Limit reached", "This is a subscription allowance, not a spending cap or an API rate limit.")
        case .resetPending: ("Reset pending", "The reset time has passed. A fresh reading will confirm the new allowance.")
        }
    }
}
