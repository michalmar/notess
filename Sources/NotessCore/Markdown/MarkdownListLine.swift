import Foundation

/// A line of a Markdown list item, as the editor lays it out: the line with
/// the item's marker, or a later line of the item's text (a continuation
/// line), which belongs to the closest item above it at `level`.
///
/// Lists inside block quotes are not reported. Ranges and offsets are UTF-16
/// offsets into the lexed text.
public struct MarkdownListLine: Hashable, Sendable {
    public enum Marker: Hashable, Sendable {
        /// `-`, `*` or `+`.
        case bullet
        /// A decimal number followed by `.` or `)`, as written.
        case number(Int)
    }

    /// The item's marker, nil on a continuation line.
    public var marker: Marker?
    /// How deep the item is nested: 0 for a top-level item. Follows the
    /// indentation relative to the enclosing items, not its width.
    public var level: Int
    /// The line without its line break.
    public var range: NSRange
    /// The marker's characters, empty at `contentStart` on a continuation line.
    public var markerRange: NSRange
    /// Where the line's text starts: after the indentation, and on a marker
    /// line also after the marker and the whitespace after it (the line's end
    /// for an empty item).
    public var contentStart: Int

    /// The whitespace before the marker or the text.
    public var indentation: NSRange {
        NSRange(location: range.location, length: (marker == nil ? contentStart : markerRange.location) - range.location)
    }

    /// Indentation, marker and the whitespace up to the text.
    public var prefix: NSRange {
        NSRange(location: range.location, length: contentStart - range.location)
    }

    /// A text change and the selection after it, both in UTF-16 offsets.
    public struct Edit: Equatable, Sendable {
        public var range: NSRange
        public var replacement: String
        public var selection: NSRange
    }

    /// The largest number an ordered marker may have: nine digits.
    static let maximumNumber = 999_999_999

    /// What Enter does with the caret at the end of this item's line: start
    /// the next item with the same indentation and marker (the next number),
    /// or, when the item has no text, turn the line into an empty one. Nil on
    /// a continuation line and when the next number would be too long.
    func newline(in text: NSString) -> Edit? {
        guard let marker else { return nil }
        let content = NSRange(location: contentStart, length: range.upperBound - contentStart)
        if text.substring(with: content).allSatisfy({ $0 == " " || $0 == "\t" }) {
            return Edit(range: range, replacement: "", selection: NSRange(location: range.location, length: 0))
        }
        var nextMarker = text.substring(with: markerRange)
        if case .number(let number) = marker {
            guard number < Self.maximumNumber else { return nil }
            let digits = (nextMarker as NSString).length - 1
            let next = String(number + 1)
            nextMarker = String(repeating: "0", count: max(0, digits - next.count)) + next + nextMarker.suffix(1)
        }
        let separator = text.substring(with: NSRange(location: markerRange.upperBound, length: contentStart - markerRange.upperBound))
        let inserted = lineBreak(in: text) + text.substring(with: indentation) + nextMarker + separator
        let caret = NSRange(location: range.upperBound + (inserted as NSString).length, length: 0)
        return Edit(range: NSRange(location: range.upperBound, length: 0), replacement: inserted, selection: caret)
    }

    /// The line's own line break, or for the last line the one before it, so
    /// a CRLF note stays CRLF.
    private func lineBreak(in text: NSString) -> String {
        let end = range.upperBound
        if end < text.length {
            return text.character(at: end) == Char.cr ? "\r\n" : "\n"
        }
        let start = range.location
        return start >= 2 && text.character(at: start - 2) == Char.cr && text.character(at: start - 1) == Char.lf ? "\r\n" : "\n"
    }
}
