import Foundation

/// A Tag (`#word`) written in a note; see `GLOSSARY.md`.
///
/// Allowed characters are letters (diacritics included), digits, `-` and `_`,
/// and a Tag needs at least one letter (`#2026` is not a Tag). Tags are not
/// hierarchical, compare case-insensitively (`normalizedName`) and are ignored
/// inside inline code, code blocks, URLs, link targets and wiki-links. A heading (`# Title`)
/// is not a Tag because of the space after the hash.
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
        let string = text as NSString
        return MarkdownSyntax.tokens(in: text).compactMap { token in
            guard token.kind == .wikiLink else { return nil }
            let content = string.substring(with: NSRange(location: token.range.location + 2, length: token.range.length - 4))
            return WikiLink(content: content, range: token.range)
        }
    }
}
