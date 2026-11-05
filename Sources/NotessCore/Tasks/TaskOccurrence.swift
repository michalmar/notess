import Foundation

/// Where a Task occurrence is written: a Daily Entry or a Free Note. Brain
/// Notes never hold Tasks of the Task Overview.
public enum TaskSource: Hashable, Sendable {
    case dailyEntry(Day)
    /// The note's file name without `.md`, and its Vault-relative folder
    /// (`""` at the Vault root), which tells same-named notes apart.
    case freeNote(name: String, folder: String)

    /// The source of the note at a Vault-relative path; nil for notes that
    /// are neither Daily Entries nor Free Notes.
    public init?(relativePath: String) {
        switch NoteKind.classify(relativePath: relativePath) {
        case .dailyEntry:
            guard let day = DailyEntry.day(forRelativePath: relativePath) else { return nil }
            self = .dailyEntry(day)
        case .freeNote:
            var components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let file = components.removeLast()
            let name = file.hasSuffix(".md") ? String(file.dropLast(3)) : file
            self = .freeNote(name: name, folder: components.joined(separator: "/"))
        case .brainNote, nil:
            return nil
        }
    }
}

/// One checkbox occurrence (see `GLOSSARY.md`, Task) in a saved note. Equal
/// text never merges occurrences: each keeps its own source and position.
public struct TaskOccurrence: Hashable, Sendable, Identifiable {
    /// The note's Vault-relative path.
    public let relativePath: String
    public let source: TaskSource
    /// The Task's position among the note's Tasks, in source-text order.
    public let ordinal: Int
    /// The Task's text after the checkbox, as written on its line.
    public let text: String
    public let isCompleted: Bool
    /// The UTF-16 offset of the `[ ]` box in the saved note.
    public let boxLocation: Int
    /// Parsed from the saved Task text; marker ranges are relative to `text`.
    public let dueDate: TaskDueDate

    public var id: String { "\(relativePath)#\(ordinal)" }

    public init(relativePath: String, source: TaskSource, ordinal: Int, text: String, isCompleted: Bool, boxLocation: Int) {
        self.relativePath = relativePath
        self.source = source
        self.ordinal = ordinal
        self.text = text
        self.isCompleted = isCompleted
        self.boxLocation = boxLocation
        self.dueDate = TaskDueDate.parse(in: text)
    }

    /// Completed Tasks never acquire an open urgency category.
    public func category(on today: Day) -> TaskFilter {
        guard !isCompleted else { return .completed }
        guard let day = dueDate.day else { return .undated }
        if day < today { return .overdue }
        return day == today ? .today : .upcoming
    }

    /// Deadlines first, undated last; equal deadlines retain source ordering.
    public static func dueDateOrder(_ lhs: TaskOccurrence, _ rhs: TaskOccurrence) -> Bool {
        switch (lhs.dueDate.day, rhs.dueDate.day) {
        case (let a?, let b?) where a != b: return a < b
        case (_?, nil): return true
        case (nil, _?): return false
        default: return sourceOrder(lhs, rhs)
        }
    }

    /// The Task's box in `currentText` (the note as open now, possibly with
    /// unsaved edits), only while the same Task is still at its saved place:
    /// the same ordinal, offset and text. Otherwise nil, so nothing unrelated
    /// is revealed.
    public func range(in currentText: String) -> NSRange? {
        let tasks = MarkdownTask.tasks(in: currentText)
        guard ordinal < tasks.count else { return nil }
        let task = tasks[ordinal]
        guard task.boxRange.location == boxLocation, task.text == text else { return nil }
        return task.boxRange
    }

    /// Source ordering: Daily Entries newest first, then Free Notes by name
    /// (then folder for equal names), and source-text order within a note.
    public static func sourceOrder(_ lhs: TaskOccurrence, _ rhs: TaskOccurrence) -> Bool {
        switch (lhs.source, rhs.source) {
        case (.dailyEntry(let a), .dailyEntry(let b)) where a != b:
            return a > b
        case (.dailyEntry, .freeNote):
            return true
        case (.freeNote, .dailyEntry):
            return false
        case (.freeNote(let nameA, let folderA), .freeNote(let nameB, let folderB)):
            let order = nameA.localizedStandardCompare(nameB)
            if order != .orderedSame { return order == .orderedAscending }
            if folderA != folderB { return folderA < folderB }
        default:
            break
        }
        if lhs.relativePath != rhs.relativePath { return lhs.relativePath < rhs.relativePath }
        return lhs.ordinal < rhs.ordinal
    }
}

/// Which Tasks the Task Overview shows.
public enum TaskFilter: Hashable, Sendable, CaseIterable {
    /// Všechny nesplněné: every Open Task.
    case open
    case overdue
    case today
    case upcoming
    case undated
    /// Splněné: every completed Task.
    case completed
}
