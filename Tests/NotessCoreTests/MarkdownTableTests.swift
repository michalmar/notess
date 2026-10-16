import Foundation
import Testing
@testable import NotessCore

@Suite("GFM tables")
struct MarkdownTableTests {
    private func cellTexts(_ row: MarkdownTable.Row, in text: String) -> [String] {
        row.cells.map { (text as NSString).substring(with: $0) }
    }

    @Test("a table lists its rows, cells between pipes and column alignments")
    func structure() throws {
        let text = "Úvod\n| Jméno | Role | Tým |\n| :--- | ---: | :-: |\n| Jan | PM |\n| a \\| b | `x` | y |\nkonec"
        let tables = MarkdownSyntax.tables(in: text)
        let table = try #require(tables.first)
        #expect(tables.count == 1)
        #expect(table.rows.map(\.kind) == [.header, .delimiter, .body, .body])
        #expect(table.alignments == [.left, .right, .center])
        #expect(cellTexts(table.rows[0], in: text) == [" Jméno ", " Role ", " Tým "])
        #expect(cellTexts(table.rows[1], in: text) == [" :--- ", " ---: ", " :-: "])
        #expect(cellTexts(table.rows[2], in: text) == [" Jan ", " PM "])
        #expect(cellTexts(table.rows[3], in: text) == [" a \\| b ", " `x` ", " y "])
        #expect((text as NSString).substring(with: table.range) == "| Jméno | Role | Tým |\n| :--- | ---: | :-: |\n| Jan | PM |\n| a \\| b | `x` | y |")
    }

    @Test("rows without outer pipes and empty cells")
    func outerPipesOptional() throws {
        let text = "a | b\n--|--\n| | d\n||"
        let table = try #require(MarkdownSyntax.tables(in: text).first)
        #expect(table.alignments == [.left, .left])
        #expect(cellTexts(table.rows[0], in: text) == ["a ", " b"])
        #expect(cellTexts(table.rows[2], in: text) == [" ", " d"])
        #expect(cellTexts(table.rows[3], in: text) == [""])
        #expect(table.rows[0].pipes == [2])
        #expect(table.rows[3].pipes == [18, 19])
    }

    @Test("separate tables, and pipes that are not tables")
    func separateTables() {
        let text = "|a|b|\n|-|-|\n\n|c|\n|-|\n\n```\n|x|\n|-|\n```\n|y|z|\n|-|"
        let tables = MarkdownSyntax.tables(in: text)
        #expect(tables.count == 2)
        #expect(tables.map { $0.rows.count } == [2, 2])
    }
}
