import Foundation

extension Day: Comparable {
    public static func < (lhs: Day, rhs: Day) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// The Journal as shown in the sidebar: years → months → days that have a file,
/// all newest first.
public struct JournalTree: Equatable, Sendable {
    public struct Month: Equatable, Sendable, Identifiable {
        public let year: Int
        public let month: Int
        public let days: [Day]
        public var id: String { "\(year)-\(month)" }
    }

    public struct Year: Equatable, Sendable, Identifiable {
        public let year: Int
        public let months: [Month]
        public var id: Int { year }
    }

    public let years: [Year]

    public init(days: [Day]) {
        let byYear = Dictionary(grouping: Set(days), by: \.year)
        years = byYear.keys.sorted(by: >).map { year in
            let byMonth = Dictionary(grouping: byYear[year]!, by: \.month)
            let months = byMonth.keys.sorted(by: >).map { month in
                Month(year: year, month: month, days: byMonth[month]!.sorted(by: >))
            }
            return Year(year: year, months: months)
        }
    }

    public static let empty = JournalTree(days: [])
}

/// A folder of the Vault outside `Journal/`, `_brain/` and `attachments/`,
/// with the Free Notes and sub-folders it contains.
public struct NotesFolder: Equatable, Sendable, Identifiable {
    public struct Note: Equatable, Sendable, Identifiable {
        public let relativePath: String
        public let title: String
        public var id: String { relativePath }
    }

    /// Empty for the Vault root.
    public let relativePath: String
    public let name: String
    public let folders: [NotesFolder]
    public let notes: [Note]
    public var id: String { relativePath }
}

public struct VaultTree: Equatable, Sendable {
    public let journal: JournalTree
    public let notes: NotesFolder
    public let brain: BrainTree

    init(journal: JournalTree, notes: NotesFolder, brain: BrainTree = .empty) {
        self.journal = journal
        self.notes = notes
        self.brain = brain
    }

    public static let empty = VaultTree(
        journal: .empty,
        notes: NotesFolder(relativePath: "", name: "", folders: [], notes: []),
        brain: .empty
    )
}

extension Vault {
    /// Scans the Vault for the sidebar. Not recursive into hidden items.
    public func scanTree() -> VaultTree {
        let days = scanJournalDays()
        return VaultTree(
            journal: JournalTree(days: days),
            notes: scanNotesFolder(relativePath: ""),
            brain: scanBrain()
        )
    }

    private func scanJournalDays() -> [Day] {
        let fm = FileManager.default
        let journalURL = rootURL.appending(path: DailyEntry.journalFolder, directoryHint: .isDirectory)
        guard let enumerator = fm.enumerator(
            at: journalURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let prefix = rootURL.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        var days: [Day] = []
        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(prefix),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            let relative = String(path.dropFirst(prefix.count))
            if let day = DailyEntry.day(forRelativePath: relative) { days.append(day) }
        }
        return days
    }

    private func scanNotesFolder(relativePath: String) -> NotesFolder {
        let fm = FileManager.default
        let folderURL = relativePath.isEmpty
            ? rootURL
            : rootURL.appending(path: relativePath, directoryHint: .isDirectory)
        let entries = (try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var folders: [NotesFolder] = []
        var notes: [NotesFolder.Note] = []
        for entry in entries {
            let name = entry.lastPathComponent
            if (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
            let childPath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory {
                if name == NoteKind.attachmentsFolder { continue }
                if relativePath.isEmpty && NoteKind.isReservedTopLevelFolder(name) { continue }
                folders.append(scanNotesFolder(relativePath: childPath))
            } else if NoteKind.classify(relativePath: childPath) == .freeNote {
                notes.append(.init(relativePath: childPath, title: String(name.dropLast(3))))
            }
        }
        let order: (String, String) -> Bool = { $0.localizedStandardCompare($1) == .orderedAscending }
        return NotesFolder(
            relativePath: relativePath,
            name: folderURL.lastPathComponent,
            folders: folders.sorted { order($0.name, $1.name) },
            notes: notes.sorted { order($0.title, $1.title) }
        )
    }

    /// Opens an existing note by its Vault-relative path.
    @MainActor
    public func openNote(relativePath: String) throws -> NoteDocument {
        let url = rootURL.appending(path: relativePath, directoryHint: .notDirectory).standardizedFileURL
        guard url.path.hasPrefix(rootURL.path + "/") else { throw CocoaError(.fileReadNoPermission) }
        return try NoteDocument.open(
            fileURL: url,
            newFileContent: "",
            isReadOnly: NoteKind.classify(relativePath: relativePath) == .brainNote
        )
    }
}
