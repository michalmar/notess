import Foundation
import Testing
@testable import NotessCore

@Suite("Manual Task Due Dates")
struct TaskDueDateTests {
    @Test("a calendar marker exposes its calendar day and exact UTF-16 source range")
    func validMarker() throws {
        let text = "📨 Poslat nabídku 📅 2026-11-06"
        let dueDate = TaskDueDate.parse(in: text)

        #expect(dueDate.state == .valid(Day(year: 2026, month: 11, day: 6)))
        let marker = try #require(dueDate.markers.first)
        #expect((text as NSString).substring(with: marker.range) == "📅 2026-11-06")
        #expect(marker.rawValue == "📅 2026-11-06")
        #expect(marker.day == Day(year: 2026, month: 11, day: 6))
    }

    @Test("missing, leap, impossible and conflicting dates are never guessed", arguments: [
        ("Bez data", TaskDueDate.State.missing),
        ("📅 2024-02-29", .valid(Day(year: 2024, month: 2, day: 29))),
        ("📅 2000-02-29", .valid(Day(year: 2000, month: 2, day: 29))),
        ("📅 1900-02-29", .invalid),
        ("📅 2026-02-29", .invalid),
        ("📅 2026-02-31", .invalid),
        ("📅 2026-04-31", .invalid),
        ("📅 2026-13-01", .invalid),
        ("📅 2026-00-01", .invalid),
        ("📅 2026-01-00", .invalid),
        ("📅 0000-01-01", .invalid),
        ("📅 2026-1-01", .invalid),
        ("📅 zítra", .invalid),
        ("📅", .invalid),
        ("📅 2026-11-06T12:00", .invalid),
        ("📅 2026-11-061", .invalid),
        ("📅 2026-11-06 📅 2026-11-07", .invalid),
        ("📅 2026-11-06 📅 2026-02-31", .invalid),
        ("📅 2026-11-06 a znovu 📅 2026-11-06", .valid(Day(year: 2026, month: 11, day: 6))),
    ])
    func interpretation(example: (String, TaskDueDate.State)) {
        #expect(TaskDueDate.parse(in: example.0).state == example.1)
    }

    @Test("source rendering gets all markers at document offsets and code examples do not assign a deadline")
    func sourceRanges() throws {
        let line = "Příklad `📅 2026-01-01` a termíny 📅 2026-11-06 📅 2026-11-07"
        let prefix = "# 📓\n\n- [ ] "
        let dueDate = TaskDueDate.parse(in: line, offset: (prefix as NSString).length)
        let document = (prefix + line) as NSString

        #expect(dueDate.state == .invalid)
        #expect(dueDate.markers.count == 2)
        #expect(dueDate.markers.map { document.substring(with: $0.range) } == ["📅 2026-11-06", "📅 2026-11-07"])
        #expect(TaskDueDate.parse(in: "Jen `📅 2026-01-01`").state == .missing)
    }

    @Test("sentence punctuation does not turn a date into an error or get swallowed by its source range")
    func punctuation() throws {
        let text = "Poslat (📅 2026-11-06), prosím."
        let dueDate = TaskDueDate.parse(in: text)
        #expect(dueDate.state == .valid(Day(year: 2026, month: 11, day: 6)))
        #expect(dueDate.markers.map(\.rawValue) == ["📅 2026-11-06"])
        #expect(dueDate.markers.map { (text as NSString).substring(with: $0.range) } == ["📅 2026-11-06"])
    }
}
