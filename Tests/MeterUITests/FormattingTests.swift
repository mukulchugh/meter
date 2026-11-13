import Foundation
import MeterCore
import Testing
@testable import MeterUI

@Suite struct FormattingTests {
    @Test func moneyFormatsFromDecimalWithSeparatorsAndCents() {
        #expect(Fmt.usd(dec("1234.5")) == "$1,234.50")
        #expect(Fmt.usd(dec("0.005")) == "$0.01")
        #expect(Fmt.usd(dec("12.344")) == "$12.34")
        #expect(Fmt.usd(dec("1000000")) == "$1,000,000.00")
        #expect(Fmt.usd(dec("-5")) == "-$5.00")
    }

    @Test func largeDecimalsKeepEveryCent() {
        // 2^53 + 1 cents would lose a cent as a Double.
        #expect(Fmt.usd(dec("90071992547409.93")) == "$90,071,992,547,409.93")
    }

    @Test func missingAmountIsNoDataNeverZero() {
        #expect(Fmt.usd(nil as Decimal?) == "No data")
        #expect(Fmt.reading(Reading(amount: nil, state: .missing)) == "No data")
        #expect(!Fmt.reading(Reading(amount: nil, state: .missing)).contains("0"))
    }

    @Test func readingTextPerState() {
        #expect(Fmt.reading(Reading(amount: dec("412"), state: .value)) == "$412.00")
        #expect(Fmt.reading(Reading(amount: dec("0"), state: .noActivity)) == "$0.00")
        #expect(Fmt.reading(Reading(amount: dec("40"), state: .partial)) == "$40.00 (partial)")
    }

    @Test func compactAmounts() {
        #expect(Fmt.usdCompact(dec("412.4")) == "$412")
        #expect(Fmt.usdCompact(dec("12.84")) == "$12.84")
        #expect(Fmt.usdCompact(dec("12345.6")) == "$12,346")
    }

    @Test func timeAndDayText() {
        #expect(Fmt.ago(t0.addingTimeInterval(-10), now: t0) == "just now")
        #expect(Fmt.ago(t0.addingTimeInterval(-600), now: t0) == "10 min ago")
        #expect(Fmt.ago(t0.addingTimeInterval(-3 * 3600), now: t0) == "3h ago")
        #expect(Fmt.ago(t0.addingTimeInterval(-3 * 86_400), now: t0) == "3d ago")
        #expect(Fmt.shortDay(day("2026-11-13")) == "Nov 13")
        #expect(Fmt.weekday(day("2026-11-13")) == "Fri")
        #expect(Fmt.weekday(day("2026-11-15")) == "Sun")
        #expect(Fmt.utcTime(utc("2026-11-13T06:05:00Z")) == "06:05 UTC")
        #expect(Fmt.percent(79.6) == "80%")
    }

    @Test func everyStateHasDistinctPlainCopy() {
        let infos = FreshnessState.allCases.map(StateInfo.of)
        #expect(infos.count == 7)
        #expect(Set(infos.map(\.label)).count == 7)
        #expect(Set(infos.map(\.symbol)).count == 7)
        for i in infos {
            #expect(!i.detail.isEmpty)
            #expect(!i.detail.contains("\u{2014}") && !i.label.contains("\u{2014}"))
        }
        #expect(StateInfo.of(.error).tone == .bad)
        #expect(StateInfo.of(.delayed).tone == .caution)
        #expect(StateInfo.of(.fresh).tone == .good)
        #expect(StateInfo.of(.unavailableDimension).tone == .muted)
    }

    @Test func noUserFacingSourceUsesAnEmDash() throws {
        let dir = SourceScan.meterUIDirectory
        for url in try SourceScan.swiftFiles(in: dir) {
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(!text.contains("\u{2014}"), "em dash in \(url.lastPathComponent)")
        }
    }

    @Test func basisLabelsAreSeparate() {
        #expect(Fmt.reportedLabel == "Reported")
        #expect(Fmt.estimateLabel == "Estimate")
        #expect(PeopleContent.estimateColumnTitle.contains("estimate"))
    }
}
