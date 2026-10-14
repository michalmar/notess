import Foundation

/// What the user typed into search: `#tag` words filter to Sections with that
/// Tag (case-insensitively, all of them must match); the other words are
/// fulltext terms that all have to occur, each also as a word prefix.
public struct SearchQuery: Equatable, Sendable {
    /// Normalised Tag names (`Tag.normalize`), without duplicates.
    public let tags: [String]
    /// Fulltext words in Unicode NFC.
    public let terms: [String]

    public init(_ text: String) {
        var tags: [String] = []
        var terms: [String] = []
        for word in text.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).map(String.init) {
            if word.hasPrefix("#"),
               let tag = Tag.tags(in: word).first,
               tag.range.location == 0,
               tag.range.length == (word as NSString).length {
                if !tags.contains(tag.normalizedName) { tags.append(tag.normalizedName) }
            } else {
                terms.append(word)
            }
        }
        self.tags = tags
        self.terms = terms
    }

    public var isEmpty: Bool { tags.isEmpty && ftsExpression == nil }

    /// The FTS5 MATCH expression for the terms, or nil when no term contains a
    /// letter or digit. Every term is quoted, so FTS5 operators are plain text.
    var ftsExpression: String? {
        let parts = terms
            .filter { $0.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) }
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
