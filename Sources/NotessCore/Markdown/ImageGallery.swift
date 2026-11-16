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
        /// The titles of the headings enclosing the occurrence, outermost
        /// first. Missing levels are not filled in; empty before any heading.
        public var headings: [String]

        public init(source: String, range: NSRange, headings: [String] = []) {
            self.source = source
            self.range = range
            self.headings = headings
        }
    }

    public private(set) var occurrences: [Occurrence]

    public init(occurrences: [Occurrence]) {
        self.occurrences = occurrences
    }

    /// The gallery of the note whose current text is `markdown`.
    ///
    /// Each occurrence's headings follow the same lexer: a heading ends the
    /// preceding headings of the same or a deeper level.
    /// `enclosingHeadings` supplies ancestors outside a displayed heading subtree.
    public init(markdown: String, enclosingHeadings: [String] = []) {
        let text = markdown as NSString
        let tokens = MarkdownLexer().reset(text: text)
            .filter {
                switch $0.kind {
                case .heading, .image: true
                default: false
                }
            }
            // A setext heading line may start with the image it contains.
            .sorted { ($0.range.location, $0.isImage ? 1 : 0) < ($1.range.location, $1.isImage ? 1 : 0) }
        var enclosing: [(level: Int, title: String)] = []
        var occurrences: [Occurrence] = []
        for token in tokens {
            switch token.kind {
            case .heading(let level):
                enclosing.removeAll { $0.level >= level }
                enclosing.append((level, NoteSection.title(of: text.substring(with: token.range))))
            case .image(let source):
                occurrences.append(Occurrence(
                    source: source, range: token.range,
                    headings: enclosingHeadings + enclosing.map(\.title).filter { !$0.isEmpty }
                ))
            default:
                break
            }
        }
        self.occurrences = occurrences
    }

    /// The position of the occurrence whose Markdown contains `location`.
    public func index(containing location: Int) -> Int? {
        occurrences.firstIndex { NSLocationInRange(location, $0.range) }
    }
}

private extension MarkdownToken {
    var isImage: Bool {
        if case .image = kind { return true }
        return false
    }
}
