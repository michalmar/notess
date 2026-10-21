import Foundation

/// Matching for finding text in the current note (Cmd+F), as opposed to the
/// fulltext search over saved files. It works on the note's in-memory text, so
/// unsaved edits are found.
public enum NoteFind {
    /// Every literal, case-insensitive occurrence of `query` in note order, as
    /// non-overlapping UTF-16 ranges. An empty query matches nothing.
    public static func matches(of query: String, in text: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let string = text as NSString
        var result: [NSRange] = []
        var searchRange = NSRange(location: 0, length: string.length)
        while searchRange.length > 0 {
            let found = string.range(of: query, options: [.caseInsensitive, .literal], range: searchRange)
            guard found.location != NSNotFound, found.length > 0 else { break }
            result.append(found)
            let next = found.location + found.length
            searchRange = NSRange(location: next, length: string.length - next)
        }
        return result
    }

    /// The index of the first match starting at or after `location`, wrapping to
    /// the first match; nil without matches.
    public static func indexOfFirstMatch(in matches: [NSRange], atOrAfter location: Int) -> Int? {
        guard !matches.isEmpty else { return nil }
        return matches.firstIndex { $0.location >= location } ?? 0
    }

    public static func index(after index: Int, count: Int) -> Int {
        count > 0 ? (index + 1) % count : 0
    }

    public static func index(before index: Int, count: Int) -> Int {
        count > 0 ? (index - 1 + count) % count : 0
    }
}
