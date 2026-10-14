import Foundation
import Testing
@testable import NotessCore

@Suite("Splitting notes into searchable Sections")
struct SearchSectionTests {
    private let dailyEntry = """
    # 2026-03-14

    Úvod dne #ranní

    ## Kickoff Acme
    Body one #acme

    ### Detail
    deeper #Projekt-X

    ## Retro
    Body two
    """

    @Test("the text before the first second-level heading is its own segment, then one per Section")
    func splitsIntoSections() {
        let sections = SearchSection.split(dailyEntry)
        #expect(sections.map(\.title) == ["2026-03-14", "Kickoff Acme", "Retro"])
        #expect(sections.map(\.ordinal) == [0, 1, 2])
        #expect(sections.map(\.body) == [
            "Úvod dne #ranní",
            "Body one #acme\n\n### Detail\ndeeper #Projekt-X",
            "Body two",
        ])
    }

    @Test("a Tag marks the whole Section it appears in, compared case-insensitively")
    func tagsApplyToSection() {
        let sections = SearchSection.split(dailyEntry)
        #expect(sections.map(\.tags) == [["ranní"], ["acme", "projekt-x"], []])
    }

    @Test("Tags inside code are ignored")
    func tagsInCode() {
        let sections = SearchSection.split("## A\n`#nope` and #yes\n```\n#neither\n```\n")
        #expect(sections.first?.tags == ["yes"])
    }

    @Test("a note without headings is one untitled segment")
    func noHeadings() {
        let sections = SearchSection.split("Jen text\n#tag")
        #expect(sections.count == 1)
        #expect(sections[0].title == nil)
        #expect(sections[0].body == "Jen text\n#tag")
        #expect(sections[0].range == NSRange(location: 0, length: 13))
    }

    @Test("empty segments are left out")
    func emptySegments() {
        let sections = SearchSection.split("\n\n## Jediná\n\ntext\n## Prázdná\n\n")
        #expect(sections.map(\.title) == ["Jediná", "Prázdná"])
        #expect(sections.map(\.body) == ["text", ""])
        #expect(SearchSection.split("   \n").isEmpty)
    }

    @Test("everything before the first second-level heading is one segment, titled by a leading first-level heading")
    func preambleWithLevelOneHeadings() {
        let titled = SearchSection.split("\n# Den\nx #ranní\n# Další\ny\n## S\nz")
        #expect(titled.map(\.title) == ["Den", "S"])
        #expect(titled.map(\.level) == [1, 2])
        #expect(titled.first?.body == "x #ranní\n# Další\ny")
        #expect(titled.first?.tags == ["ranní"])

        let untitled = SearchSection.split("Úvod\n# Den\nx\n## S\nz")
        #expect(untitled.map(\.title) == [nil, "S"])
        #expect(untitled.first?.body == "Úvod\n# Den\nx")
    }

    @Test("after a Section, a first-level heading ends it and starts a new segment")
    func levelOneHeading() {
        let sections = SearchSection.split("## A\na\n# Nový díl\nb\n## B\nc")
        #expect(sections.map(\.title) == ["A", "Nový díl", "B"])
        #expect(sections.map(\.level) == [2, 1, 2])
    }

    @Test("the heading range points at the heading line")
    func headingRange() throws {
        let sections = SearchSection.split(dailyEntry)
        let retro = try #require(sections.last)
        #expect((dailyEntry as NSString).substring(with: try #require(retro.headingRange)) == "## Retro")
    }

    @Test("locating a Section in edited text prefers the same title")
    func locate() throws {
        let edited = "# 2026-03-14\n\n## Nová\nx\n## Kickoff Acme\ny\n## Retro\nz"
        let found = try #require(SearchSection.locate(title: "Kickoff Acme", ordinal: 1, in: edited))
        #expect(found.ordinal == 2)
        #expect(SearchSection.locate(title: "Retro", ordinal: 2, in: edited)?.ordinal == 3)
        #expect(SearchSection.locate(title: "Zmizelá", ordinal: 1, in: edited)?.ordinal == 1)
        #expect(SearchSection.locate(title: "Zmizelá", ordinal: 9, in: edited)?.ordinal == 3)
        #expect(SearchSection.locate(title: nil, ordinal: 0, in: "") == nil)
    }
}
