import Foundation
import Testing
@testable import MeterCore

@Suite struct MoneyTests {
    @Test func anthropicCentsString() {
        // Legacy cost_report: "123.45" = $1.23 (RESEARCH.md 2.1).
        #expect(Money.usd(fromAnthropicCents: "123.45") == dec("1.2345"))
        #expect(Money.usd(fromAnthropicCents: "123.78912") == dec("1.2378912"))
        #expect(Money.usd(fromAnthropicCents: "0") == 0)
        #expect(Money.usd(fromAnthropicCents: "not a number") == nil)
        #expect(Money.usd(fromAnthropicCents: "") == nil)
    }

    @Test func anthropicSixDecimalCents() {
        #expect(Money.usd(fromAnthropicCents: "41280.000000") == dec("412.8"))
        #expect(Money.usd(fromAnthropicCents: "0.000001") == dec("0.00000001"))
        // A large value that a Double cannot hold exactly.
        #expect(Money.string(Money.usd(fromAnthropicCents: "123456789012345678.123456")!) == "1234567890123456.78123456")
    }

    @Test func openAIDollarsFloat() throws {
        let j = try JSON.parse(Data(#"{"value": 0.06, "currency": "usd"}"#.utf8))
        #expect(j["value"].decimal == dec("0.06"))
        #expect(Money.string(j["value"].decimal!) == "0.06")
        // Exact: 6 cents, not 0.059999999999999997...
        #expect(j["value"].decimal! * 100 == 6)
        #expect(Money.usd(fromOpenAIDollars: "1.234567") == dec("1.234567"))
    }

    @Test func floatingPointDriftDoesNotCreep() throws {
        let a = try JSON.parse(Data("0.1".utf8)).decimal!
        let b = try JSON.parse(Data("0.2".utf8)).decimal!
        #expect(a + b == dec("0.3"))
        // Summing 10,000 ten-cent lines is exactly $1,000.
        #expect((0..<10_000).reduce(Decimal(0)) { acc, _ in acc + a } == 1000)
    }

    @Test func exponentNumberToken() throws {
        #expect(try JSON.parse(Data("1e-7".utf8)).decimal == dec("0.0000001"))
    }

    @Test func nsNumberUsesStringForm() {
        #expect(Money.decimal(from: NSNumber(value: 0.06)) == dec("0.06"))
        #expect(Money.decimal(from: NSNumber(value: 12)) == 12)
    }

    @Test func plainStringNeverUsesExponent() {
        #expect(Money.string(dec("0.0000001")) == "0.0000001")
        #expect(Money.string(dec("-0")) == "0")
        #expect(Money.string(dec("1000000")) == "1000000")
    }

    @Test func jsonParserHandlesEscapesAndNesting() throws {
        let j = try JSON.parse(Data(#"{"a":[1,{"b":"x\"yé😀"}],"c":null,"d":true}"#.utf8))
        #expect(j["a"].array[1]["b"].string == "x\"y\u{e9}\u{1F600}")
        #expect(j["c"].isNull)
        #expect(j["d"].bool == true)
        #expect(throws: JSON.ParseError.self) { try JSON.parse(Data("{".utf8)) }
        #expect(throws: JSON.ParseError.self) { try JSON.parse(Data("[1,]x".utf8)) }
    }

    @Test func utcDayRoundTrips() {
        #expect(day("2026-11-13").string == "2026-11-13")
        #expect(day("2024-02-29").adding(1).string == "2024-03-01")
        #expect(UTCDay(string: "2026-02-30") == nil)
        #expect(day("2026-11-13").monthStart.string == "2026-11-01")
        #expect(day("2026-12-05").nextMonthStart.string == "2027-01-01")
        #expect(day("2026-02-10").daysInMonth == 28)
        #expect(UTCDay(Date(timeIntervalSince1970: 1_730_419_200)).string == "2024-11-01")
        #expect(day("2026-11-13").unixStart == 1_794_528_000)
    }
}
