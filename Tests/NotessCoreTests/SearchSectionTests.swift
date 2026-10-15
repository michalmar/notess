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

    // MARK: - Tags in headings

    private func tags(_ text: String) -> [Set<String>] { SearchSection.split(text).map(\.tags) }

    @Test("a Tag in an H2 heading marks the Section that heading starts, not its neighbours")
    func tagInSecondLevelHeading() {
        let text = "# Den\n\nÚvod\n\n## Porada #Acme\ntext\n\n## Retro\ntext\n"
        #expect(SearchSection.split(text).map(\.title) == ["Den", "Porada #Acme", "Retro"])
        #expect(tags(text) == [[], ["acme"], []])
    }

    @Test("a Tag in an H1 heading marks the Section it starts")
    func tagInFirstLevelHeading() {
        let text = "## A\na\n# Nový díl #acme\nb\n## B\nc\n"
        #expect(tags(text) == [[], ["acme"], []])
    }

    @Test("a Tag in a deeper heading belongs to its enclosing Section")
    func tagInDeeperHeading() {
        let text = "## A\na\n### Detail #acme\n#### Ještě hlouběji #projekt\n###### H6 #x1a\n## B\nb\n"
        #expect(tags(text) == [["acme", "projekt", "x1a"], []])
    }

    @Test("Tags in the introductory Section stay local, whatever the heading level they are in")
    func introductoryTagsStayLocal() {
        let text = "# Den #ranní\n\nÚvod #úvod\n### Pod #nadpis\n\n## Porada\ntext\n\n## Retro #acme\ntext\n"
        #expect(tags(text) == [["ranní", "úvod", "nadpis"], [], ["acme"]])

        let untitled = "Úvod #úvod\n#### Hluboký #h\n## S\nx\n"
        #expect(tags(untitled) == [["úvod", "h"], []])
    }

    @Test("a Section with only a heading is still a complete matching Section")
    func headingOnlySection() throws {
        let text = "## Porada #acme\n## Další\ntext\n"
        let sections = SearchSection.split(text)
        #expect(sections.map(\.title) == ["Porada #acme", "Další"])
        #expect(sections[0].body == "")
        #expect(sections[0].tags == ["acme"])
        #expect(sections[0].range == NSRange(location: 0, length: ("## Porada #acme\n" as NSString).length))

        let last = SearchSection.split("## Poslední #acme")
        #expect(last.count == 1)
        #expect(last[0].tags == ["acme"])
    }

    @Test("closing hashes and setext headings do not hide a heading Tag")
    func headingForms() {
        #expect(tags("## Porada #acme ##\n") == [["acme"]])
        #expect(tags("## Porada #acme #\n") == [["acme"]])
        #expect(tags("## #acme\n") == [["acme"]])
        #expect(tags("Porada #acme\n---\ntext\n") == [["acme"]])
        #expect(tags("# Den\n\nÚvod\n\nPorada #acme\n---\ntext\n\nDruhá\n---\n") == [[], ["acme"], []])
        #expect(SearchSection.split("Porada #acme\n---\ntext\n").first?.title == "Porada #acme")
    }

    @Test("heading Tags ignore code, URLs, link targets and wiki-links")
    func headingExclusions() {
        let text = """
        ## `#kod` [odkaz](https://a.cz/#frag) <https://b.cz/#c> https://c.cz/#d [[Poznámka#Sekce]] C#
        text

        ## [#vTextu](https://a.cz/#cil) #ano
        ```
        ## Nadpis #neni
        ```
        """
        #expect(tags(text) == [[], ["ano", "vtextu"]])
    }

    @Test("heading Tags are case-insensitive, Unicode-normalised and deduplicated with body Tags")
    func headingNormalizationAndDuplicates() {
        let decomposed = "## Porada #Cafe\u{301}\ntext #café #CAFÉ\n### Detail #Café\n"
        #expect(tags(decomposed) == [["café"]])
        #expect(SearchSection.split("## A #acme #ACME #Acme\n#acme").first?.tags == ["acme"])
    }
}
