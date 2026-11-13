import Foundation
import MeterCore

/// Number and time formatting. Money stays `Decimal`; the only Double use in this module is chart geometry.
public enum Fmt {
    public static let noData = "No data"
    public static let reportedLabel = "Reported"
    public static let estimateLabel = "Estimate"

    private static let locale = Locale(identifier: "en_US")

    /// `$1,234.56`, rounded to cents half away from zero.
    public static func usd(_ d: Decimal) -> String {
        Money.rounded(d).formatted(.currency(code: "USD").locale(locale))
    }

    /// `$412` for large amounts, `$12.84` for small ones. Used where space is tight (menu bar).
    public static func usdCompact(_ d: Decimal) -> String {
        let a = d < 0 ? -d : d
        if a >= 100 {
            return Money.rounded(d, scale: 0).formatted(.currency(code: "USD").locale(locale).precision(.fractionLength(0)))
        }
        return usd(d)
    }

    /// An optional amount: a missing value is "No data", never `$0.00`.
    public static func usd(_ d: Decimal?) -> String { d.map(usd) ?? noData }

    public static func reading(_ r: Reading) -> String {
        switch r.state {
        case .missing: noData
        case .partial: r.amount.map { usd($0) + " (partial)" } ?? noData
        case .noActivity: usd(r.amount ?? 0)
        case .value: usd(r.amount)
        }
    }

    public static func percent(_ p: Double) -> String { "\(Int(p.rounded()))%" }

    public static func share(_ s: Double?) -> String { s.map { percent($0 * 100) } ?? "n/a" }

    /// "3h ago", "12 min ago", "just now".
    public static func ago(_ date: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(date))
        switch s {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(s / 60)) min ago"
        case ..<86_400: return "\(Int(s / 3600))h ago"
        default: return "\(Int(s / 86_400))d ago"
        }
    }

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// "Nov 13". Days are UTC days, so no time zone is involved.
    public static func shortDay(_ d: UTCDay) -> String { "\(months[d.month - 1]) \(d.day)" }

    public static func weekday(_ d: UTCDay) -> String { weekdays[((d.daysSinceEpoch + 4) % 7 + 7) % 7] }

    public static func monthName(_ d: UTCDay) -> String { months[d.month - 1] }

    /// "06:00 UTC".
    public static func utcTime(_ date: Date) -> String {
        let s = Int(date.timeIntervalSince1970)
        let m = ((s % 86_400) + 86_400) % 86_400 / 60
        return String(format: "%02d:%02d UTC", m / 60, m % 60)
    }

    public static func count(_ n: Int) -> String { n.formatted(.number.locale(locale)) }

    /// A chart-geometry value. The only place money becomes a Double.
    public static func chartValue(_ d: Decimal) -> Double { NSDecimalNumber(decimal: d).doubleValue }
}
