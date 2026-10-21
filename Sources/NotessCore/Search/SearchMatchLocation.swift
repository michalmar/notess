import Foundation

extension SearchQuery {
    /// The first Section (`SearchSection.split`, in note order) that carries
    /// every Tag and contains every term, ignoring case and diacritics, the way
    /// the index matches: a term's words adjacent, each a whole word except
    /// the last, which is a word prefix. Within it the earliest term or Tag.
    /// `text` is the note's current text, so unsaved edits count. When no
    /// Section matches any more, the Section `title`/`ordinal` found by the
    /// index (`SearchSection.locate`) is returned at its heading, or at the
    /// note's start.
    public func firstMatchRange(in text: String, title: String?, ordinal: Int) -> NSRange {
        let string = text as NSString
        let sections = SearchSection.split(text)
        let phrases = termPhrases
        let tagRanges = tagRanges(in: text)
        for section in sections where tags.allSatisfy(section.tags.contains) {
            var earliest: NSRange?
            var isComplete = true
            for phrase in phrases {
                guard let found = Self.firstPhrase(phrase, in: string, within: section.range) else {
                    isComplete = false
                    break
                }
                if found.location < (earliest?.location ?? .max) { earliest = found }
            }
            guard isComplete else { continue }
            if let tag = tagRanges.first(where: { NSLocationInRange($0.location, section.range) }),
               tag.location < (earliest?.location ?? .max) {
                earliest = tag
            }
            if let earliest { return earliest }
        }
        guard let section = SearchSection.locate(title: title, ordinal: ordinal, in: text) else {
            return NSRange(location: 0, length: 0)
        }
        return section.headingRange ?? NSRange(location: section.range.location, length: 0)
    }

    /// Each fulltext term as its letter-and-digit runs, as the index tokenizes
    /// it (`unicode61`); terms without any are ignored, as in `ftsExpression`.
    private var termPhrases: [[String]] {
        terms
            .map { $0.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty } }
            .filter { !$0.isEmpty }
    }

    /// Ranges of the query's Tags in `text`, `#` included, in text order; Tags
    /// in code and links do not count, as when indexing.
    private func tagRanges(in text: String) -> [NSRange] {
        guard !tags.isEmpty else { return [] }
        let string = text as NSString
        return MarkdownSyntax.tokens(in: text)
            .filter { token in
                token.kind == .tag && tags.contains(Tag.normalize(string.substring(with: NSRange(
                    location: token.range.location + 1,
                    length: token.range.length - 1
                ))))
            }
            .map(\.range)
            .sorted { $0.location < $1.location }
    }

    private static let matching: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// The first occurrence of `words` in `range`: they start a word, follow
    /// each other with only non-word characters between, and all but the last
    /// end a word.
    private static func firstPhrase(_ words: [String], in string: NSString, within range: NSRange) -> NSRange? {
        var searchRange = range
        while searchRange.length > 0 {
            let first = string.range(of: words[0], options: matching, range: searchRange)
            guard first.location != NSNotFound else { return nil }
            if !isWordCharacter(before: first.location, in: string),
               let end = phraseEnd(words.dropFirst(), after: first, in: string, limit: NSMaxRange(range)) {
                return NSRange(location: first.location, length: end - first.location)
            }
            let next = NSMaxRange(string.rangeOfComposedCharacterSequence(at: first.location))
            searchRange = NSRange(location: next, length: NSMaxRange(range) - next)
        }
        return nil
    }

    private static func phraseEnd(_ words: ArraySlice<String>, after first: NSRange, in string: NSString, limit: Int) -> Int? {
        var end = NSMaxRange(first)
        for word in words {
            guard end < limit, !isWordCharacter(at: end, in: string) else { return nil }
            var next = end
            while next < limit, !isWordCharacter(at: next, in: string) {
                next = NSMaxRange(string.rangeOfComposedCharacterSequence(at: next))
            }
            let found = string.range(
                of: word,
                options: matching.union(.anchored),
                range: NSRange(location: next, length: limit - next)
            )
            guard found.location != NSNotFound else { return nil }
            end = NSMaxRange(found)
        }
        return end
    }

    private static func isWordCharacter(before location: Int, in string: NSString) -> Bool {
        location > 0 && isWordCharacter(at: location - 1, in: string)
    }

    private static func isWordCharacter(at location: Int, in string: NSString) -> Bool {
        let character = string.substring(with: string.rangeOfComposedCharacterSequence(at: location))
        return character.unicodeScalars.first.map(CharacterSet.alphanumerics.contains) ?? false
    }
}
