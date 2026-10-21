import Foundation
import Testing
@testable import NotessCore

@Suite("First match location of a search result")
struct SearchMatchLocationTests {
    private func match(_ query: String, in text: String, title: String? = nil, ordinal: Int = 0) -> String {
        let range = SearchQuery(query).firstMatchRange(in: text, title: title, ordinal: ordinal)
        return "\(range.location):" + (text as NSString).substring(with: range)
    }

    private func location(of needle: String, in text: String, after marker: String = "") -> Int {
        let string = text as NSString
        let start = marker.isEmpty ? 0 : NSMaxRange(string.range(of: marker))
        return string.range(of: needle, range: NSRange(location: start, length: string.length - start)).location
    }

    @Test("the first match is in the first Section that matches, a heading word included")
    func firstMatchingSection() {
        let text = "# 2026-03-14\n\nRáno káva.\n\n## Kickoff Acme\nPřehled od klienta.\n\n## Retro\nKickoff šel dobře.\n"
        #expect(match("kickoff", in: text) == "\(location(of: "Kickoff", in: text)):Kickoff")
        #expect(match("dobře", in: text) == "\(location(of: "dobře", in: text)):dobře")
    }

    @Test("all terms must match in the same Section, and the earliest term there is the location")
    func termsShareSection() {
        let text = "## A\nalfa jen\n\n## B\nbeta jen\n\n## C\nnejdřív beta, pak alfa\n"
        #expect(match("alfa beta", in: text) == "\(location(of: "beta", in: text, after: "## C")):beta")
    }

    @Test("matching ignores case and diacritics and needs a word prefix, not an inner substring")
    func prefixAndNormalisation() {
        let text = "## X\nnehledám nic\n\n## Y\nPřehled požadavků\n"
        #expect(match("PREHL", in: text) == "\(location(of: "Přehl", in: text)):Přehl")
        #expect(match("pozadavku", in: text) == "\(location(of: "požadavků", in: text)):požadavků")
        #expect(match("hled", in: text, title: "Y", ordinal: 1) == "\(location(of: "## Y", in: text)):## Y")
    }

    @Test("a term of several words matches them adjacent, whole words then a prefix, as the index's phrase does")
    func multiWordTerm() {
        let text = "## A\nfood a barn\n\n## B\nfoox-barva\n\n## C\nFoo – Barevný\n"
        #expect(match("foo-bar", in: text) == "\(location(of: "Foo", in: text, after: "## C")):Foo – Bar")
        #expect(match("foo bar", in: text) == "\(location(of: "food", in: text)):foo")
    }

    @Test("a Tag matches its exact normalised name outside code; Tag and text must share the Section")
    func tags() {
        let text = "## A\nacme jako slovo #acmex\n\n## B\n`#acme` v kódu\n\n## C\nText #Acme a další\n\n## D\n#acme\n"
        #expect(match("#acme", in: text) == "\(location(of: "#Acme", in: text)):#Acme")
        #expect(match("#ACME text", in: text) == "\(location(of: "Text", in: text)):Text")
        #expect(match("#acme další", in: text) == "\(location(of: "#Acme", in: text)):#Acme")
    }

    @Test("the location comes from the current text, unsaved edits included")
    func currentText() {
        let text = "# Plán\n\nNový úvod\n\n## Kickoff\nKickoff s klientem\n"
        #expect(match("kickoff", in: text, title: "Kickoff", ordinal: 0) == "\(location(of: "Kickoff", in: text)):Kickoff")
    }

    @Test("when nothing matches any more, the result's Section is revealed at its heading, or the note's start")
    func fallback() {
        let text = "# Plán\n\n## Retro\nzměněný text\n\n## Další\n"
        #expect(match("zmizelo", in: text, title: "Retro", ordinal: 1) == "\(location(of: "## Retro", in: text)):## Retro")
        #expect(match("zmizelo", in: "", title: nil, ordinal: 0) == "0:")
    }
}
