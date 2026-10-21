import Foundation

/// Text with the parts that matched a search marked, for previews.
public struct SearchSnippet: Hashable, Sendable {
    public struct Part: Hashable, Sendable {
        public let text: String
        public let isMatch: Bool
    }

    public let parts: [Part]

    public var text: String { parts.map(\.text).joined() }

    /// Parses text in which every match is wrapped in `start`/`end` markers;
    /// runs of whitespace (line breaks included) become single spaces.
    init(marked: String, start: Character, end: Character) {
        var parts: [Part] = []
        var current = ""
        var isMatch = false
        func flush() {
            if !current.isEmpty { parts.append(Part(text: current, isMatch: isMatch)) }
            current = ""
        }
        for character in Self.collapsingWhitespace(marked) {
            if character == start || character == end {
                flush()
                isMatch = character == start
            } else {
                current.append(character)
            }
        }
        flush()
        self.parts = parts
    }

    /// A preview of `text` around the first case-insensitive occurrence of
    /// `needle` (highlighted), at most about `maxLength` characters long.
    init(text: String, highlighting needle: String, maxLength: Int = 120) {
        let flat = Self.collapsingWhitespace(text)
        guard let match = flat.range(of: needle, options: [.caseInsensitive]) else {
            let clipped = flat.count > maxLength ? String(flat.prefix(maxLength)) + "…" : flat
            parts = clipped.isEmpty ? [] : [Part(text: clipped, isMatch: false)]
            return
        }
        let before = flat[..<match.lowerBound]
        let leading = before.count > maxLength / 3 ? "…" + before.suffix(maxLength / 3) : String(before)
        let after = flat[match.upperBound...]
        let remaining = max(0, maxLength - leading.count - flat[match].count)
        let trailing = after.count > remaining ? after.prefix(remaining) + "…" : String(after)
        parts = [
            Part(text: leading, isMatch: false),
            Part(text: String(flat[match]), isMatch: true),
            Part(text: trailing, isMatch: false),
        ].filter { !$0.text.isEmpty }
    }

    private static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// A note found by `SearchIndex`: one result per matching file, shown by its
/// first matching Section. Matching itself stays per Section.
public struct SearchResult: Hashable, Sendable, Identifiable {
    public let relativePath: String
    public let kind: NoteKind
    /// Position of the first matching Section in the note (`SearchSection.ordinal`).
    public let ordinal: Int
    /// That Section's heading, or nil for untitled text at the start of a note.
    public let title: String?
    /// The heading with matches marked; empty without a heading.
    public let highlightedTitle: SearchSnippet
    /// A short excerpt of that Section's text with matches marked.
    public let snippet: SearchSnippet
    /// Ordinals of every matching Section of the note, ascending.
    public let matchingOrdinals: [Int]
    /// The query that found the note, to locate its first match when opened.
    public let query: SearchQuery

    public var id: String { relativePath }

    /// The note's file name without `.md`.
    public var noteName: String {
        URL(filePath: relativePath).deletingPathExtension().lastPathComponent
    }

    /// Where to open the note: the query's first match in `text`, the note's
    /// current text, which may hold unsaved edits (see `SearchQuery.firstMatchRange`).
    public func firstMatchRange(in text: String) -> NSRange {
        query.firstMatchRange(in: text, title: title, ordinal: ordinal)
    }
}

/// Search results of one kind of note, in display order Journal, Notes, Brain.
public struct SearchResultGroup: Hashable, Sendable, Identifiable {
    public let kind: NoteKind
    public let results: [SearchResult]

    public var id: NoteKind { kind }
}
