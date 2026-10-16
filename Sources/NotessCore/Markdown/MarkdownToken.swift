import Foundation

/// A span of Markdown text with a syntactic meaning, used for live formatting,
/// Tag and wiki-link recognition.
///
/// Ranges are UTF-16 offsets (`NSRange`) so they map directly onto `NSString`
/// and `NSTextStorage`. Tokens may nest: a `.heading` covers the whole line,
/// its `#` characters are additionally a `.syntaxMarker`.
public struct MarkdownToken: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A whole ATX (`# …`) or setext heading line.
        case heading(level: Int)
        case strong
        case emphasis
        case strikethrough
        /// The content of a `` `code` `` span (without the backticks).
        case inlineCode
        /// A content line of a fenced or indented code block.
        case codeBlock
        /// A line of the YAML front matter at the top of a note.
        case frontMatter
        /// A whole `> quote` line.
        case blockquote
        /// The bullet or number of a list item.
        case listMarker
        /// The `[ ]` / `[x]` box of a task list item.
        case task(isChecked: Bool)
        /// The text of a checked task.
        case completedTask
        /// The header row of a table.
        case tableHeader
        case thematicBreak
        /// Link text, an autolink or a bare URL.
        case link
        /// The `url "title"` part of an inline link.
        case linkDestination
        /// A whole inline image and its source path.
        case image(source: String)
        /// A whole `[[target#Section]]` wiki-link, brackets included.
        case wikiLink
        /// A whole `#tag`, hash included.
        case tag
        /// Markup characters that stay visible but are shown muted
        /// (`#`, `**`, `` ` ``, `>`, fences, table pipes, link brackets, …).
        case syntaxMarker
    }

    public var kind: Kind
    public var range: NSRange

    public init(kind: Kind, range: NSRange) {
        self.kind = kind
        self.range = range
    }
}

/// One-shot Markdown tokenisation of a whole text.
public enum MarkdownSyntax {
    /// All tokens of `text`, ordered by line.
    public static func tokens(in text: String) -> [MarkdownToken] {
        MarkdownLexer().reset(text: text as NSString)
    }

    /// All GFM tables of `text`, in order.
    public static func tables(in text: String) -> [MarkdownTable] {
        MarkdownLexer().relexAll(text: text as NSString).tables
    }
}
