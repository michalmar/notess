import Foundation
import Testing
@testable import NotessCore

@Suite("Section lookup")
struct NoteSectionTests {
    private let text = """
    # 2026-03-14

    Úvod

    ## Kickoff Acme
    Body one

    ### Detail
    deeper

    ## Retro
    Body two
    """

    private func slice(_ range: NSRange) -> String {
        (text as NSString).substring(with: range)
    }

    @Test("finds a second-level heading and its heading line")
    func findsHeading() throws {
        let section = try #require(NoteSection.find("Retro", in: text))
        #expect(section.title == "Retro")
        #expect(section.level == 2)
        #expect(slice(section.headingRange) == "## Retro")
    }

    @Test("matching ignores case and extra whitespace")
    func caseInsensitive() throws {
        let section = try #require(NoteSection.find("  kickoff   ACME ", in: text))
        #expect(section.title == "Kickoff Acme")
        #expect(NoteSection.find("RETRO", in: text)?.title == "Retro")
    }

    @Test("matching handles diacritics case-insensitively")
    func diacritics() throws {
        let czech = "## Přehled Žádostí\nx\n## Další\ny"
        #expect(NoteSection.find("přehled žádostí", in: czech)?.title == "Přehled Žádostí")
        #expect(NoteSection.find("DALŠÍ", in: czech)?.title == "Další")
    }

    @Test("a Section runs to the next second-level heading and includes deeper headings")
    func sectionRange() throws {
        let section = try #require(NoteSection.find("Kickoff Acme", in: text))
        #expect(slice(section.range) == "## Kickoff Acme\nBody one\n\n### Detail\ndeeper\n\n")
        let last = try #require(NoteSection.find("Retro", in: text))
        #expect(slice(last.range) == "## Retro\nBody two")
    }

    @Test("a missing heading finds nothing")
    func missing() {
        #expect(NoteSection.find("Neexistuje", in: text) == nil)
        #expect(NoteSection.find("", in: text) == nil)
        #expect(NoteSection.find("Úvod", in: text) == nil)
    }

    @Test("closing hashes are not part of the title")
    func closingHashes() {
        #expect(NoteSection.find("Plán", in: "## Plán ##\nx")?.title == "Plán")
        #expect(NoteSection.find("C#", in: "## C#\nx")?.title == "C#")
    }

    @Test("a second-level heading wins over other levels; then the first wins")
    func ambiguity() throws {
        let doc = "# Plán\n### Plán\n## Plán\nA\n## Plán\nB"
        let section = try #require(NoteSection.find("plán", in: doc))
        #expect(section.level == 2)
        #expect((doc as NSString).substring(with: section.range) == "## Plán\nA\n")
        #expect(NoteSection.find("Plán", in: "### Plán\nx")?.level == 3)
    }

    @Test("finds a later occurrence after edits move duplicate Section titles")
    func occurrence() throws {
        let doc = "úvod\n## Stav\nA\n## Jiná\nB\n## Stav\nC"
        let section = try #require(NoteSection.find("Stav", occurrence: 1, in: doc))
        #expect((doc as NSString).substring(with: section.range) == "## Stav\nC")
    }

    @Test("headings inside code blocks are ignored")
    func codeBlocks() {
        let doc = "```\n## Fake\n```\n## Real\nx"
        #expect(NoteSection.find("Fake", in: doc) == nil)
        #expect(NoteSection.find("Real", in: doc) != nil)
    }

    @Test("setext headings are found")
    func setext() throws {
        let section = try #require(NoteSection.find("Titulek", in: "Titulek\n-------\ntext"))
        #expect(section.level == 2)
    }
}
