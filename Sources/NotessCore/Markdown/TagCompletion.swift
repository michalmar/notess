import Foundation

/// Where Tag completion applies: a collapsed caret after `#` and at least one
/// Tag-name character, in a place where Tags are recognised.
public struct TagCompletionContext: Equatable, Sendable {
    /// The name characters between the `#` and the caret, as written.
    public let prefix: String
    /// UTF-16 range of the whole Tag token around the caret, `#` included.
    /// Accepting a suggestion replaces this range.
    public let tokenRange: NSRange
    /// UTF-16 offset of the caret.
    public let caret: Int

    public init(prefix: String, tokenRange: NSRange, caret: Int) {
        self.prefix = prefix
        self.tokenRange = tokenRange
        self.caret = caret
    }

    /// The prefix as matched against the vocabulary.
    public var normalizedPrefix: String { Tag.normalize(prefix) }
}

/// Tag completion rules shared by the editor and the Search Index; see
/// `GLOSSARY.md` (Tag).
public enum TagCompletion {
    /// The completion context at `caret` in `text`, lexing it from scratch.
    /// The editor uses its incremental lexer instead
    /// (`MarkdownLexer.tagCompletionContext(at:in:)`).
    public static func context(in text: String, caret: Int) -> TagCompletionContext? {
        let string = text as NSString
        let lexer = MarkdownLexer()
        lexer.reset(text: string)
        return lexer.tagCompletionContext(at: caret, in: string)
    }

    /// Normalised vocabulary names that start with the normalised `prefix`,
    /// deduplicated and sorted. A name equal to the prefix is left out (there
    /// is nothing to complete); there is no fuzzy, substring or diacritic-
    /// insensitive matching and no cutoff.
    public static func candidates(matching prefix: String, in vocabulary: some Sequence<String>) -> [String] {
        let needle = Tag.normalize(prefix)
        guard !needle.isEmpty else { return [] }
        let matches = Set(vocabulary.lazy.map(Tag.normalize).filter { $0 != needle && $0.hasPrefix(needle) })
        return matches.sorted(by: sortsBefore)
    }

    /// The order of Tags in suggestions and Tag lists.
    static func sortsBefore(_ lhs: String, _ rhs: String) -> Bool {
        switch lhs.localizedStandardCompare(rhs) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: lhs < rhs
        }
    }
}
