import Foundation

/// Exact money conversions. Nothing here touches `Double`.
///
/// Three encodings exist (RESEARCH.md sections 2.1 and 2.2):
/// - Anthropic legacy `cost_report`: `amount` is a decimal string in cents, e.g. `"123.45"` = $1.23.
/// - Anthropic `analytics/cost`: `cost.amount` is a decimal string in cents with six decimals,
///   e.g. `"41280.000000"` = $412.80.
/// - OpenAI `organization/costs`: `amount.value` is a JSON number in dollars, e.g. `0.06`.
public enum Money {
    /// Locale-independent exact parse. Accepts plain and exponent forms.
    public static func decimal(from text: String) -> Decimal? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return Decimal(string: t, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Anthropic amounts (both endpoints): cents in a decimal string, converted to dollars.
    public static func usd(fromAnthropicCents cents: String) -> Decimal? {
        decimal(from: cents).map { $0 / 100 }
    }

    /// OpenAI amounts: dollars. Pass the original JSON number token, not a Double.
    public static func usd(fromOpenAIDollars token: String) -> Decimal? {
        decimal(from: token)
    }

    /// Exact conversion from an `NSNumber` through its string form (never `doubleValue`).
    public static func decimal(from number: NSNumber) -> Decimal? {
        decimal(from: number.stringValue)
    }

    /// Plain decimal text for CSV and storage, never exponent notation.
    public static func string(_ d: Decimal) -> String {
        var v = d
        if v.isNaN { return "0" }
        // Decimal.description is plain for the magnitudes seen here; normalise "-0".
        if v == 0 { v = 0 }
        return NSDecimalNumber(decimal: v).description(withLocale: Locale(identifier: "en_US_POSIX"))
    }

    /// Display rounding to cents (half away from zero is bankers-free here: `.plain`).
    public static func rounded(_ d: Decimal, scale: Int = 2) -> Decimal {
        var src = d
        var out = Decimal()
        NSDecimalRound(&out, &src, scale, .plain)
        return out
    }
}
