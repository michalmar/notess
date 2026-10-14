import Foundation

/// A Section of a note (see `GLOSSARY.md`): the span from one second-level
/// heading to the next heading of level 1 or 2. Deeper headings belong to the
/// Section they appear in.
public struct NoteSection: Hashable, Sendable {
    /// The heading text without `#` markers and closing `#`s, trimmed.
    public let title: String
    /// Heading level, 1...6.
    public let level: Int
    /// UTF-16 range of the heading line (without the line break).
    public let headingRange: NSRange
    /// UTF-16 range from the start of the heading line to the start of the next
    /// level 1 or 2 heading (or the end of the text).
    public let range: NSRange

    /// Finds the heading a `[[note#Section]]` link points to.
    ///
    /// Matching ignores case, surrounding whitespace and differences in Unicode
    /// normalisation. A second-level heading wins over a heading of another
    /// level; among equals the first one in the note wins. Headings inside code
    /// blocks are not headings. Returns nil when no heading matches.
    public static func find(_ name: String, in text: String) -> NoteSection? {
        find(name, occurrence: 0, in: text)
    }

    /// Finds a particular occurrence of a same-named second-level heading.
    ///
    /// This lets navigation relocate an indexed Section after unsaved edits
    /// moved it within the note.
    public static func find(_ name: String, occurrence: Int, in text: String) -> NoteSection? {
        guard occurrence >= 0 else { return nil }
        let wanted = normalize(name)
        guard !wanted.isEmpty else { return nil }
        let matches = headings(in: text).filter { normalize($0.title) == wanted }
        let secondLevel = matches.filter { $0.level == 2 }
        if secondLevel.indices.contains(occurrence) {
            return secondLevel[occurrence]
        }
        return occurrence == 0 ? matches.first : nil
    }

    /// All headings of `text` in order, each with the range it spans.
    static func headings(in text: String) -> [NoteSection] {
        let string = text as NSString
        let headingTokens = MarkdownSyntax.tokens(in: text).compactMap { token -> (level: Int, range: NSRange)? in
            guard case .heading(let level) = token.kind else { return nil }
            return (level, token.range)
        }
        return headingTokens.enumerated().map { index, heading in
            let end = headingTokens[(index + 1)...].first(where: { $0.level <= 2 })
                .map { lineStart(of: $0.range.location, in: string) } ?? string.length
            let start = lineStart(of: heading.range.location, in: string)
            return NoteSection(
                title: title(of: string.substring(with: heading.range)),
                level: heading.level,
                headingRange: heading.range,
                range: NSRange(location: start, length: max(0, end - start))
            )
        }
    }

    private static func lineStart(of location: Int, in string: NSString) -> Int {
        string.lineRange(for: NSRange(location: location, length: 0)).location
    }

    /// The text of a heading line: ATX markers and the optional closing `#`s are
    /// removed; a setext heading line is already plain text.
    static func title(of line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("#") else { return text }
        text = String(text.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
        if let lastSpace = text.lastIndex(where: { $0 == " " || $0 == "\t" }),
           text[text.index(after: lastSpace)...].allSatisfy({ $0 == "#" }) {
            text = String(text[..<lastSpace]).trimmingCharacters(in: .whitespaces)
        } else if text.allSatisfy({ $0 == "#" }) {
            text = ""
        }
        return text
    }

    static func normalize(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .precomposedStringWithCanonicalMapping.lowercased()
    }
}
