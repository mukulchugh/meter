import Foundation

/// A calendar day in UTC. Both providers bucket by UTC day (RESEARCH.md section 8, "Timezone").
public struct UTCDay: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let daysSinceEpoch: Int

    public init(daysSinceEpoch: Int) { self.daysSinceEpoch = daysSinceEpoch }

    public init(_ date: Date) {
        self.daysSinceEpoch = Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    public init(year: Int, month: Int, day: Int) {
        // Howard Hinnant's days_from_civil.
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        self.daysSinceEpoch = era * 146_097 + doe - 719_468
    }

    /// Parses `yyyy-MM-dd`, or the first ten characters of an ISO 8601 timestamp.
    public init?(string: String) {
        let head = string.prefix(10)
        let parts = head.split(separator: "-", omittingEmptySubsequences: false)
        guard head.count == 10, parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        let candidate = UTCDay(year: y, month: m, day: d)
        guard candidate.year == y, candidate.month == m, candidate.day == d else { return nil }
        self = candidate
    }

    private var civil: (year: Int, month: Int, day: Int) {
        let z = daysSinceEpoch + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }

    public var year: Int { civil.year }
    public var month: Int { civil.month }
    public var day: Int { civil.day }

    public var start: Date { Date(timeIntervalSince1970: TimeInterval(daysSinceEpoch) * 86_400) }
    /// Exclusive end: the start of the next day.
    public var end: Date { adding(1).start }
    public var unixStart: Int { daysSinceEpoch * 86_400 }

    public var string: String {
        let c = civil
        return String(format: "%04d-%02d-%02d", c.year, c.month, c.day)
    }
    public var description: String { string }

    public func adding(_ days: Int) -> UTCDay { UTCDay(daysSinceEpoch: daysSinceEpoch + days) }
    public func days(until other: UTCDay) -> Int { other.daysSinceEpoch - daysSinceEpoch }

    public var monthStart: UTCDay { adding(1 - day) }
    public var nextMonthStart: UTCDay {
        let c = civil
        return c.month == 12 ? UTCDay(year: c.year + 1, month: 1, day: 1) : UTCDay(year: c.year, month: c.month + 1, day: 1)
    }
    public var daysInMonth: Int { monthStart.days(until: nextMonthStart) }
    public var monthEnd: UTCDay { nextMonthStart.adding(-1) }
    public var previousMonthStart: UTCDay { monthStart.adding(-1).monthStart }

    public static func < (a: UTCDay, b: UTCDay) -> Bool { a.daysSinceEpoch < b.daysSinceEpoch }

    /// Every day from `from` through `through`, inclusive. Empty when `through < from`.
    public static func range(from: UTCDay, through: UTCDay) -> [UTCDay] {
        guard from <= through else { return [] }
        return (from.daysSinceEpoch...through.daysSinceEpoch).map(UTCDay.init(daysSinceEpoch:))
    }
}

enum ISODate {
    static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
