import Foundation
import Testing
@testable import NotessCore

@Suite("Find in note")
struct NoteFindTests {
    private func slices(_ matches: [NSRange], in text: String) -> [String] {
        matches.map { (text as NSString).substring(with: $0) }
    }

    @Test("matches ignore case and keep the note's own spelling")
    func caseInsensitive() {
        let text = "Plán plán PLÁN planet"
        let matches = NoteFind.matches(of: "plán", in: text)
        #expect(slices(matches, in: text) == ["Plán", "plán", "PLÁN"])
    }

    @Test("matches are listed in note order and do not overlap")
    func orderAndOverlap() {
        let matches = NoteFind.matches(of: "aa", in: "aaaa x aa")
        #expect(matches.map(\.location) == [0, 2, 7])
    }

    @Test("an empty query matches nothing")
    func emptyQuery() {
        #expect(NoteFind.matches(of: "", in: "text").isEmpty)
    }

    @Test("a query is literal, not a pattern")
    func literal() {
        let text = "a.c abc (x) [[wiki]]"
        #expect(slices(NoteFind.matches(of: "a.c", in: text), in: text) == ["a.c"])
        #expect(slices(NoteFind.matches(of: "(x)", in: text), in: text) == ["(x)"])
        #expect(slices(NoteFind.matches(of: "[[wiki]]", in: text), in: text) == ["[[wiki]]"])
    }

    @Test("emoji and other multi-unit characters give UTF-16 ranges")
    func utf16Ranges() {
        let text = "😀 ahoj 😀 ahoj"
        let matches = NoteFind.matches(of: "ahoj", in: text)
        #expect(matches == [NSRange(location: 3, length: 4), NSRange(location: 11, length: 4)])
    }

    @Test("the first match to select is the one at or after the caret, wrapping to the start")
    func firstMatchFromCaret() {
        let matches = [NSRange(location: 2, length: 1), NSRange(location: 10, length: 1)]
        #expect(NoteFind.indexOfFirstMatch(in: matches, atOrAfter: 0) == 0)
        #expect(NoteFind.indexOfFirstMatch(in: matches, atOrAfter: 2) == 0)
        #expect(NoteFind.indexOfFirstMatch(in: matches, atOrAfter: 3) == 1)
        #expect(NoteFind.indexOfFirstMatch(in: matches, atOrAfter: 11) == 0)
        #expect(NoteFind.indexOfFirstMatch(in: [], atOrAfter: 0) == nil)
    }

    @Test("next and previous wrap around the matches")
    func stepping() {
        #expect(NoteFind.index(after: 0, count: 3) == 1)
        #expect(NoteFind.index(after: 2, count: 3) == 0)
        #expect(NoteFind.index(before: 1, count: 3) == 0)
        #expect(NoteFind.index(before: 0, count: 3) == 2)
        #expect(NoteFind.index(after: 0, count: 1) == 0)
    }
}
