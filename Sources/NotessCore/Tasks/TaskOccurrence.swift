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
    /// The titles of the headings the Task lies under in the saved note,
    /// outermost first; empty for a Task before the first heading.
    public let headingPath: [String]
    /// The text of the Tasks enclosing this one in nested lists, outermost first.
    public let enclosingTasks: [String]
    /// The Task's position among the saved note's Tasks with the same text,
    /// heading path and enclosing Tasks, and how many there were.
    let twinIndex: Int
    let twinCount: Int
    let twinFingerprint: String?

    public var id: String { "\(relativePath)#\(ordinal)" }

    public init(
        relativePath: String, source: TaskSource, ordinal: Int, text: String, isCompleted: Bool, boxLocation: Int,
        headingPath: [String] = [], enclosingTasks: [String] = [], twinIndex: Int = 0, twinCount: Int = 1,
        twinFingerprint: String? = nil
    ) {
        self.relativePath = relativePath
        self.source = source
        self.ordinal = ordinal
        self.text = text
        self.isCompleted = isCompleted
        self.boxLocation = boxLocation
        self.dueDate = TaskDueDate.parse(in: text)
        self.headingPath = headingPath
        self.enclosingTasks = enclosingTasks
        self.twinIndex = twinIndex
        self.twinCount = twinCount
        self.twinFingerprint = twinFingerprint
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

    /// Where the Task is in a note's current text, which may differ from the
    /// saved note by unsaved edits.
    public enum Location: Equatable, Sendable {
        /// The Task's `[ ]` box in the current text.
        case found(NSRange)
        /// No Task with this text under the same headings and enclosing Tasks.
        case missing
        /// Identical Tasks or their surrounding source changed, so identity is uncertain.
        case ambiguous
    }

    /// Finds this saved Task in `currentText` by its text, heading path and
    /// enclosing Tasks, never by a saved offset or the first matching text.
    /// Among identical Tasks, its saved position counts only while their
    /// count and source span are unchanged. Unique Tasks can change checkbox state.
    public func locate(in currentText: String) -> Location {
        let twins = MarkdownTask.Twins(text: text, headingPath: headingPath, enclosingTasks: enclosingTasks)
        let current = MarkdownTask.tasks(in: currentText)
        let candidates = current.filter { $0.twins == twins }
        if candidates.isEmpty { return .missing }
        guard candidates.count == twinCount, twinIndex < candidates.count else { return .ambiguous }
        if twinCount > 1 {
            let ranks = MarkdownTask.twinRanks(of: current, in: currentText as NSString)
            guard let twinFingerprint, ranks[candidates[twinIndex].ordinal].fingerprint == twinFingerprint else {
                return .ambiguous
            }
        }
        return .found(candidates[twinIndex].boxRange)
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
