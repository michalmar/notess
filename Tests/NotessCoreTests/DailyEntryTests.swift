import Foundation
import Testing
@testable import NotessCore

@Suite("Daily Entry")
struct DailyEntryTests {
    @Test("path is Journal/YYYY/MM/YYYY-MM-DD.md")
    func relativePath() {
        let entry = DailyEntry(day: Day(year: 2026, month: 10, day: 14))
        #expect(entry.relativePath == "Journal/2026/10/2026-10-14.md")
    }

    @Test("month and day are zero-padded in path and title")
    func zeroPadding() {
        let entry = DailyEntry(day: Day(year: 2027, month: 3, day: 5))
        #expect(entry.relativePath == "Journal/2027/03/2027-03-05.md")
        #expect(entry.title == "2027-03-05")
    }

    @Test("title is the ISO date")
    func title() {
        let entry = DailyEntry(day: Day(year: 2026, month: 10, day: 14))
        #expect(entry.title == "2026-10-14")
    }

    @Test("a new Daily Entry starts with the # YYYY-MM-DD heading")
    func initialContent() {
        let entry = DailyEntry(day: Day(year: 2026, month: 1, day: 2))
        #expect(entry.initialContent == "# 2026-01-02\n\n")
    }

    @Test("day is taken from the given calendar's time zone, not UTC")
    func dayFromDateUsesCalendarTimeZone() throws {
        // 2026-10-14T23:30:00Z is already 15 October in Prague (UTC+2).
        let instant = try #require(ISO8601DateFormatter().date(from: "2026-10-14T23:30:00Z"))
        var prague = Calendar(identifier: .gregorian)
        prague.timeZone = try #require(TimeZone(identifier: "Europe/Prague"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))

        #expect(Day(date: instant, calendar: prague) == Day(year: 2026, month: 10, day: 15))
        #expect(Day(date: instant, calendar: utc) == Day(year: 2026, month: 10, day: 14))
    }

    @Test("Daily Entry for a date resolves through the calendar")
    func entryForDate() throws {
        let instant = try #require(ISO8601DateFormatter().date(from: "2026-12-31T23:30:00Z"))
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let entry = DailyEntry(date: instant, calendar: tokyo)
        #expect(entry.relativePath == "Journal/2027/01/2027-01-01.md")
    }
}
