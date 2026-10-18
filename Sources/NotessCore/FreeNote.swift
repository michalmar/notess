import Foundation

public enum FreeNoteError: Error, LocalizedError, Equatable {
    case reservedFolder

    public var errorDescription: String? {
        switch self {
        case .reservedFolder:
            "Poznámku nelze vytvořit ve složce Journal ani _brain."
        }
    }
}

/// Rules for a note the user creates outside the Journal: its starting
/// content and the file name derived from its `# Title` heading.
public enum FreeNote {
    public static let defaultFileStem = "Bez názvu"
    static let maxStemLength = 100

    /// `---\ncreated: YYYY-MM-DD\n---\n\n# ` — the cursor lands after `# `.
    public static func initialContent(createdOn day: Day) -> String {
        "---\ncreated: \(day.isoString)\n---\n\n# "
    }

    /// Text of the first level-one heading after any front-matter, or `nil`.
    /// Reads lines lazily and stops as soon as the answer is known.
    public static func title(in text: String) -> String? {
        var lines = LineReader(text: text)
        return title(scanning: &lines)
    }

    /// Same result as `title(in:)` over the given lines, consuming only as
    /// many lines as needed. Unclosed front-matter has no known answer until
    /// EOF, so it reads to the end.
    static func title<Lines: IteratorProtocol>(scanning lines: inout Lines) -> String?
    where Lines.Element == String {
        guard let first = lines.next() else { return nil }
        guard first == "---" else {
            return heading(in: first) ?? firstHeading(in: &lines)
        }
        var pending: String?
        while let line = lines.next() {
            if line == "---" { return firstHeading(in: &lines) }
            pending = pending ?? heading(in: line)
        }
        return pending
    }

    private static func firstHeading<Lines: IteratorProtocol>(in lines: inout Lines) -> String?
    where Lines.Element == String {
        while let line = lines.next() {
            if let title = heading(in: line) { return title }
        }
        return nil
    }

    private static func heading(in line: String) -> String? {
        guard line.hasPrefix("# ") || line == "#" else { return nil }
        return String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces)
    }

    /// A file name stem (no extension) that is safe on the file system.
    /// Diacritics are kept; path separators and control characters are
    /// removed. Falls back to `defaultFileStem` for an empty result.
    public static func fileStem(forTitle title: String?) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters).union(.newlines)
        let cleaned = (title ?? "").unicodeScalars
            .map { forbidden.contains($0) ? " " : String($0) }
            .joined()
        var stem = cleaned
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .precomposedStringWithCanonicalMapping
        while stem.hasPrefix(".") { stem.removeFirst() }
        stem = stem.trimmingCharacters(in: .whitespaces)
        if stem.count > maxStemLength {
            stem = String(stem.prefix(maxStemLength)).trimmingCharacters(in: .whitespaces)
        }
        return stem.isEmpty ? defaultFileStem : stem
    }

    /// `folder/<stem>.md`, or `<stem> 2.md`, `<stem> 3.md`… if that exists.
    public static func availableURL(
        inFolder folderURL: URL,
        stem: String,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        var candidate = folderURL.appending(path: "\(stem).md", directoryHint: .notDirectory)
        var number = 2
        while fileExists(candidate) {
            candidate = folderURL.appending(path: "\(stem) \(number).md", directoryHint: .notDirectory)
            number += 1
        }
        return candidate
    }
}

/// Lazily yields the lines `text.split(separator: "\n", omittingEmptySubsequences: false)`
/// would produce, each with trailing `\r` trimmed. Splitting on `Character`
/// keeps a `\r\n` pair together, matching the eager split this replaces.
private struct LineReader: IteratorProtocol {
    private var characters: String.Iterator
    private var isFinished = false

    init(text: String) {
        characters = text.makeIterator()
    }

    mutating func next() -> String? {
        guard !isFinished else { return nil }
        var line = ""
        while let character = characters.next() {
            if character == "\n" {
                return line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            }
            line.append(character)
        }
        isFinished = true
        return line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
    }
}

extension Vault {
    /// A new Free Note in a Vault-relative folder ("" is the root). Nothing
    /// is written until the first save (ADR 0003).
    @MainActor
    public func newFreeNote(inFolder relativeFolder: String, on day: Day) throws -> NoteDocument {
        let parts = relativeFolder.split(separator: "/").map(String.init)
        guard !parts.contains(where: { $0 == ".." || $0 == "." || $0.hasPrefix(".") }),
              !(parts.first.map(NoteKind.isReservedTopLevelFolder) ?? false),
              !parts.contains(NoteKind.attachmentsFolder)
        else { throw FreeNoteError.reservedFolder }
        let folderURL = parts.reduce(rootURL) { $0.appending(path: $1, directoryHint: .isDirectory) }
        return NoteDocument.newFreeNote(inFolder: folderURL, content: FreeNote.initialContent(createdOn: day))
    }
}
