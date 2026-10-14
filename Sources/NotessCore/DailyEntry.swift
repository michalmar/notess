import Foundation

/// The one note per calendar day, stored at `Journal/YYYY/MM/YYYY-MM-DD.md`
/// and starting with the heading `# YYYY-MM-DD`.
public struct DailyEntry: Hashable, Sendable {
    public static let journalFolder = "Journal"

    public let day: Day

    public init(day: Day) {
        self.day = day
    }

    public init(date: Date, calendar: Calendar = .current) {
        self.init(day: Day(date: date, calendar: calendar))
    }

    /// `YYYY-MM-DD`.
    public var title: String { day.isoString }

    /// Path relative to the Vault root.
    public var relativePath: String {
        "\(Self.journalFolder)/\(day.yearString)/\(day.monthString)/\(title).md"
    }

    /// Content of a Daily Entry that does not exist on disk yet.
    public var initialContent: String { "# \(title)\n\n" }
}
