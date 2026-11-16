import Foundation

/// The Image Gallery of one note: every image occurrence in its Markdown, in
/// document order, regardless of headings, folding or what the editor shows.
///
/// Membership follows the Markdown lexer, so image-like text in code or other
/// non-image content is not part of it. Repeated insertions of one source stay
/// separate occurrences.
public struct ImageGallery: Equatable, Sendable {
    public struct Occurrence: Hashable, Sendable {
        /// The image source as written in the note.
        public var source: String
        /// The whole `![alt](source)` in the note's text. It identifies the
        /// occurrence and places it among the note's headings.
        public var range: NSRange

        public init(source: String, range: NSRange) {
            self.source = source
            self.range = range
        }
    }

    public private(set) var occurrences: [Occurrence]

    public init(occurrences: [Occurrence]) {
        self.occurrences = occurrences
    }

    /// The gallery of the note whose current text is `markdown`.
    public init(markdown: String) {
        let tokens = MarkdownLexer().reset(text: markdown as NSString)
        occurrences = tokens
            .compactMap { token -> Occurrence? in
                guard case .image(let source) = token.kind else { return nil }
                return Occurrence(source: source, range: token.range)
            }
            .sorted { $0.range.location < $1.range.location }
    }

    /// The position of the occurrence whose Markdown contains `location`.
    public func index(containing location: Int) -> Int? {
        occurrences.firstIndex { NSLocationInRange(location, $0.range) }
    }
}
