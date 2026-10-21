import Foundation

/// One searchable span of a note: a Section (see `GLOSSARY.md`), the text
/// before the first second-level heading, or the text after a first-level
/// heading that ends a Section, up to the next Section. This is the unit search
/// matches and Tags mark.
public struct SearchSection: Hashable, Sendable {
    /// Position among the note's non-empty segments, starting at 0.
    public let ordinal: Int
    /// Text of the level 1 or 2 heading that starts the segment, or nil when it
    /// starts without one (the beginning of a note that has no leading `#` title).
    public let title: String?
    /// Level of that heading (1 or 2), or nil.
    public let level: Int?
    /// UTF-16 range of the heading line, or nil.
    public let headingRange: NSRange?
    /// UTF-16 range of the whole segment, heading included.
    public let range: NSRange
    /// The segment's text without its heading line, trimmed.
    public let body: String
    /// Normalised names (`Tag.normalize`) of the Tags written in the segment,
    /// headings included, each once. A Tag in a deeper heading belongs to the
    /// enclosing segment; a Tag in the introductory segment stays in it and is
    /// never inherited by later segments.
    public let tags: Set<String>

    /// Splits a note at every second-level heading. Everything before the first
    /// one is a single segment, titled by its first-level heading when the note
    /// starts with one; after that a first-level heading ends the Section and
    /// starts a new segment. Headings inside code are not headings; deeper
    /// headings stay in their Section. Segments with only whitespace are left out.
    public static func split(_ text: String) -> [SearchSection] {
        let string = text as NSString
        let tokens = MarkdownSyntax.tokens(in: text)
        let headings: [(level: Int, heading: NSRange)] = tokens.compactMap { token in
            guard case .heading(let level) = token.kind, level <= 2 else { return nil }
            return (level, token.range)
        }
        let tagTokens = tokens.filter { $0.kind == .tag }

        var spans: [(level: Int?, heading: NSRange?, start: Int)] = [(nil, nil, 0)]
        var isInPreamble = true
        for heading in headings {
            let start = string.lineRange(for: NSRange(location: heading.heading.location, length: 0)).location
            if heading.level == 1 && isInPreamble {
                let before = string.substring(to: start).trimmingCharacters(in: .whitespacesAndNewlines)
                if spans[0].heading == nil && before.isEmpty {
                    spans[0] = (1, heading.heading, 0)
                }
                continue
            }
            isInPreamble = false
            spans.append((heading.level, heading.heading, start))
        }

        var sections: [SearchSection] = []
        for (index, span) in spans.enumerated() {
            let end = index + 1 < spans.count ? spans[index + 1].start : string.length
            let range = NSRange(location: span.start, length: end - span.start)
            let segment = string.substring(with: range)
            guard !segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            var bodyStart = span.start
            if let heading = span.heading {
                bodyStart = NSMaxRange(string.lineRange(for: heading))
                // A setext heading is underlined on the following line.
                if bodyStart < end {
                    let underline = string.lineRange(for: NSRange(location: bodyStart, length: 0))
                    let line = string.substring(with: underline).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !line.isEmpty, line.allSatisfy({ $0 == "=" || $0 == "-" }),
                       !string.substring(with: heading).hasPrefix("#") {
                        bodyStart = min(end, NSMaxRange(underline))
                    }
                }
            }
            let body = string.substring(with: NSRange(location: bodyStart, length: max(0, end - bodyStart)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let tags = Set(tagTokens.filter { NSLocationInRange($0.range.location, range) }.map { token in
                Tag.normalize(string.substring(with: NSRange(location: token.range.location + 1, length: token.range.length - 1)))
            })
            sections.append(SearchSection(
                ordinal: sections.count,
                title: span.heading.map { NoteSection.title(of: string.substring(with: $0)) },
                level: span.level,
                headingRange: span.heading,
                range: range,
                body: body,
                tags: tags
            ))
        }
        return sections
    }

    /// Finds a segment found by search in the note's current text, which may
    /// have changed since it was indexed: the segment at `ordinal` if its title
    /// still matches, else the first segment with that title, else the segment
    /// at `ordinal` (or the last one). Nil only for an empty note.
    public static func locate(title: String?, ordinal: Int, in text: String) -> SearchSection? {
        let sections = split(text)
        if sections.indices.contains(ordinal), sections[ordinal].title == title {
            return sections[ordinal]
        }
        if let title, let match = sections.first(where: { $0.title == title }) {
            return match
        }
        return sections.indices.contains(ordinal) ? sections[ordinal] : sections.last
    }
}
