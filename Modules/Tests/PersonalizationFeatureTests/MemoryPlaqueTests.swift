import Foundation
@testable import PersonalizationFeature
import Testing

/// BRAND-04: the `ADDED 12 OCT` plaque under each Memory entry.
@Suite("Memory plaques")
struct MemoryPlaqueTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? .distantPast
    }

    @Test func todayAndYesterdayAreSaidInWords() {
        let now = date(2026, 10, 25, hour: 18)
        #expect(MemorySummaryModel.addedText(date(2026, 10, 25, hour: 0), now: now, calendar: calendar) == "Added today")
        #expect(MemorySummaryModel.addedText(date(2026, 10, 24, hour: 23), now: now, calendar: calendar) == "Added yesterday")
    }

    @Test func thisYearIsDayAndMonth() {
        let now = date(2026, 10, 25)
        #expect(MemorySummaryModel.addedText(date(2026, 10, 12), now: now, calendar: calendar) == "Added 12 Oct")
        #expect(MemorySummaryModel.addedText(date(2026, 9, 3), now: now, calendar: calendar) == "Added 3 Sep")
    }

    @Test func earlierYearsAddTheYear() {
        let now = date(2026, 1, 5)
        #expect(MemorySummaryModel.addedText(date(2025, 12, 30), now: now, calendar: calendar) == "Added 30 Dec 2025")
    }
}
