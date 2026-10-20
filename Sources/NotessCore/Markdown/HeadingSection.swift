import Foundation

/// A heading and its descendants, ending at the next heading of equal or
/// higher rank. Text before the first heading is a separate, unheaded span.
public struct HeadingSection: Hashable, Sendable {
    public let ordinal: Int
    public let title: String?
    public let level: Int?
    public let headingRange: NSRange?
    public let range: NSRange
    /// The subtree without the heading line (or its setext underline).
    public let bodyRange: NSRange
    /// Tags in this heading's own text, not in its child headings.
    public let tags: Set<String>

    public static func split(_ text: String) -> [HeadingSection] {
        split(text, tokens: MarkdownSyntax.tokens(in: text))
    }

    /// Reuses tokens from an incremental lexer.
    public static func split(_ text: String, tokens: [MarkdownToken]) -> [HeadingSection] {
        let string = text as NSString
        let headings = tokens.compactMap { token -> (level: Int, range: NSRange)? in
            guard case .heading(let level) = token.kind else { return nil }
            return (level, token.range)
        }
        let tags = tokens.filter { $0.kind == .tag }
        var result: [HeadingSection] = []
        let firstStart = headings.first.map { string.lineRange(for: $0.range).location } ?? string.length

        func tagNames(in range: NSRange) -> Set<String> {
            Set(tags.filter { NSLocationInRange($0.range.location, range) }.map {
                Tag.normalize(string.substring(with: $0.range))
            })
        }

        if firstStart > 0,
           !string.substring(to: firstStart).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let range = NSRange(location: 0, length: firstStart)
            result.append(HeadingSection(
                ordinal: 0, title: nil, level: nil, headingRange: nil,
                range: range, bodyRange: range, tags: tagNames(in: range)
            ))
        }
        for (index, heading) in headings.enumerated() {
            let start = string.lineRange(for: heading.range).location
            let next = index + 1
            let end = headings[next...].first { $0.level <= heading.level }
                .map { string.lineRange(for: $0.range).location } ?? string.length
            let ownEnd = next < headings.count
                ? string.lineRange(for: headings[next].range).location : string.length
            var bodyStart = NSMaxRange(string.lineRange(for: heading.range))
            if !string.substring(with: heading.range).trimmingCharacters(in: .whitespaces).hasPrefix("#"),
               bodyStart < end {
                bodyStart = NSMaxRange(string.lineRange(for: NSRange(location: bodyStart, length: 0)))
            }
            result.append(HeadingSection(
                ordinal: result.count,
                title: NoteSection.title(of: string.substring(with: heading.range)),
                level: heading.level,
                headingRange: heading.range,
                range: NSRange(location: start, length: end - start),
                bodyRange: NSRange(location: bodyStart, length: max(0, end - bodyStart)),
                tags: tagNames(in: NSRange(location: start, length: ownEnd - start))
            ))
        }
        return result
    }

    /// Relocates a saved heading in current (possibly unsaved) text.
    public static func locate(title: String?, ordinal: Int, in text: String) -> HeadingSection? {
        let sections = split(text)
        if sections.indices.contains(ordinal), sections[ordinal].title == title {
            return sections[ordinal]
        }
        if let match = sections.first(where: { $0.title == title }) { return match }
        return sections.indices.contains(ordinal) ? sections[ordinal] : sections.last
    }
}
