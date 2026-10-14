import Foundation

/// What a Markdown file in the Vault is, decided purely from its path.
public enum NoteKind: Hashable, Sendable {
    case dailyEntry
    case freeNote
    case brainNote

    public static let brainFolder = "_brain"
    public static let attachmentsFolder = "attachments"

    /// Classifies a Vault-relative path such as `Journal/2026/03/2026-03-14.md`.
    /// Returns `nil` for anything that is not a note: non-Markdown files,
    /// hidden files, attachments, and files in `Journal/` that do not follow
    /// the Daily Entry layout.
    public static func classify(relativePath: String) -> NoteKind? {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard let fileName = parts.last, parts.count >= 1,
              fileName.hasSuffix(".md"), fileName.count > 3,
              !parts.contains(where: { $0.hasPrefix(".") }),
              !parts.dropLast().contains(attachmentsFolder)
        else { return nil }

        switch parts[0] {
        case brainFolder where relativePath == Vault.brainInstructionsRelativePath:
            // The user's own, editable instructions for the Agent.
            return .freeNote
        case brainFolder where parts.count > 1:
            return .brainNote
        case DailyEntry.journalFolder where parts.count > 1:
            return DailyEntry.day(forRelativePath: relativePath) == nil ? nil : .dailyEntry
        default:
            return .freeNote
        }
    }

    /// Whether a top-level folder name is outside the Notes section.
    static func isReservedTopLevelFolder(_ name: String) -> Bool {
        name == DailyEntry.journalFolder || name == brainFolder
    }
}

extension DailyEntry {
    /// The day of a Vault-relative path of the exact form `Journal/YYYY/MM/YYYY-MM-DD.md`.
    public static func day(forRelativePath path: String) -> Day? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[0] == journalFolder, parts[3].hasSuffix(".md") else { return nil }
        let stem = String(parts[3].dropLast(3))
        let pieces = stem.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3,
              pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]),
              (1...12).contains(month), day >= 1
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let length = calendar.range(of: .day, in: .month, for: first)?.count,
              day <= length
        else { return nil }
        let result = Day(year: year, month: month, day: day)
        guard parts[1] == result.yearString, parts[2] == result.monthString else { return nil }
        return result
    }
}
