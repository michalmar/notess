import Foundation

/// A Tag (`#word`) written in a note; see `GLOSSARY.md`.
///
/// Allowed characters are letters (diacritics included), digits, `-` and `_`,
/// and a Tag needs at least one letter (`#2026` is not a Tag). Tags are not
/// hierarchical, compare case-insensitively (`normalizedName`) and are ignored
/// inside inline code, code blocks, URLs, link targets and wiki-links. A heading (`# Title`)
/// is not a Tag because of the space after the hash, but a Tag written in a
/// heading of any level is one (`## Porada #acme`); which Section it marks is
/// decided by `SearchSection.split`, the single place that assigns Tags to Sections.
public struct Tag: Hashable, Sendable {
    /// The name as written, without the leading `#`.
    public let name: String
    /// UTF-16 range of the whole Tag including the `#`.
    public let range: NSRange

    public init(name: String, range: NSRange) {
        self.name = name
        self.range = range
    }

    /// The name used to compare Tags: case-folded and Unicode-normalised.
    public var normalizedName: String { Self.normalize(name) }

    /// Normalises a Tag name (with or without the leading `#`) for comparison.
    public static func normalize(_ name: String) -> String {
        let bare = name.hasPrefix("#") ? String(name.dropFirst()) : name
        return bare.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// All Tags in `text`, in order of appearance.
    public static func tags(in text: String) -> [Tag] {
        let string = text as NSString
        return MarkdownSyntax.tokens(in: text).compactMap { token in
            guard token.kind == .tag else { return nil }
            let name = string.substring(with: NSRange(location: token.range.location + 1, length: token.range.length - 1))
            return Tag(name: name, range: token.range)
        }
    }
}

/// A `[[target]]` or `[[target#Section]]` wiki-link written in a note.
public struct WikiLink: Hashable, Sendable {
    /// The linked note's name (the part before `#`), trimmed. Empty for a
    /// link to a Section of the same note (`[[#Section]]`).
    public let target: String
    /// The Section heading after `#`, trimmed, or nil.
    public let section: String?
    /// UTF-16 range of the whole link including the brackets.
    public let range: NSRange

    public init(target: String, section: String?, range: NSRange) {
        self.target = target
        self.section = section
        self.range = range
    }

    /// Parses the text between `[[` and `]]`.
    public init(content: String, range: NSRange) {
        let parts = content.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        target = parts[0].trimmingCharacters(in: .whitespaces)
        let section = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        self.section = section.isEmpty ? nil : section
        self.range = range
    }

    /// All wiki-links in `text` outside code, in order of appearance.
    public static func links(in text: String) -> [WikiLink] {
        links(in: text, tokens: MarkdownSyntax.tokens(in: text))
    }

    /// `links(in:)` from tokens already produced for `text`.
    static func links(in text: String, tokens: [MarkdownToken]) -> [WikiLink] {
        let string = text as NSString
        return tokens.compactMap { token in
            guard token.kind == .wikiLink else { return nil }
            let content = string.substring(with: NSRange(location: token.range.location + 2, length: token.range.length - 4))
            return WikiLink(content: content, range: token.range)
        }
    }
}

/// An HTTP(S) link written in Markdown, with the text range that activates it.
///
/// A Markdown link contributes one value for its label and one for its visible
/// destination. Bare URLs and autolinks contribute their URL text. Links in
/// code and image syntax are excluded by the Markdown lexer.
public struct WebLink: Hashable, Sendable {
    public let url: URL
    /// UTF-16 range that opens `url` when Command-clicked.
    public let range: NSRange

    public init(url: URL, range: NSRange) {
        self.url = url
        self.range = range
    }

    public static func links(in text: String) -> [WebLink] {
        let string = text as NSString
        let tokens = MarkdownSyntax.tokens(in: text)
        let imageRanges = tokens.compactMap { token -> NSRange? in
            if case .image = token.kind { token.range } else { nil }
        }
        func isInImage(_ range: NSRange) -> Bool {
            imageRanges.contains {
                NSLocationInRange(range.location, $0) && range.upperBound <= $0.upperBound
            }
        }
        func httpURL(_ source: String) -> URL? {
            guard let url = URL(string: source),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            return url
        }
        func destination(after link: MarkdownToken) -> MarkdownLinkDestination.Parsed? {
            for token in tokens where token.kind == .linkDestination && token.range.location >= link.range.upperBound {
                let gap = NSRange(
                    location: link.range.upperBound,
                    length: token.range.location - link.range.upperBound
                )
                guard string.substring(with: gap) == "](" else { continue }
                let value = string.substring(with: token.range)
                guard let parsed = MarkdownLinkDestination.parse(
                    Array(value.utf16), from: 0, to: value.utf16.count
                ) else {
                    return nil
                }
                return parsed
            }
            return nil
        }

        var result: [WebLink] = []
        for token in tokens {
            switch token.kind {
            case .link where !isInImage(token.range):
                let source: String
                if let destination = destination(after: token) {
                    source = destination.source
                } else {
                    source = string.substring(with: token.range)
                }
                if let url = httpURL(source) {
                    result.append(WebLink(url: url, range: token.range))
                }
            case .linkDestination where !isInImage(token.range):
                let value = string.substring(with: token.range)
                guard let parsed = MarkdownLinkDestination.parse(
                    Array(value.utf16), from: 0, to: value.utf16.count
                ), let url = httpURL(parsed.source) else { continue }
                result.append(WebLink(
                    url: url,
                    range: NSRange(
                        location: token.range.location + parsed.range.lowerBound,
                        length: parsed.range.count
                    )
                ))
            default:
                break
            }
        }
        return result
    }
}
