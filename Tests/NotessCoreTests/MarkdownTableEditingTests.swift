import Foundation
import Testing
@testable import NotessCore

@Suite("Editing GFM tables")
struct MarkdownTableEditingTests {
    /// `text` with `‸` marking the caret; returns the text after the edit with
    /// `‸` at the new caret (or `[`…`]` around a selection), nil without an edit.
    private func run(_ text: String, _ make: (MarkdownTable, Int, NSString) -> MarkdownTable.Edit?) -> String? {
        let caret = (text as NSString).range(of: "‸").location
        let plain = text.replacingOccurrences(of: "‸", with: "") as NSString
        let lexer = MarkdownLexer()
        lexer.relexAll(text: plain)
        guard let table = lexer.table(containing: caret, in: plain),
              let edit = make(table, caret, plain) else { return nil }
        let result = NSMutableString(string: plain.replacingCharacters(in: edit.range, with: edit.replacement))
        if edit.selection.length == 0 {
            result.insert("‸", at: edit.selection.location)
        } else {
            result.insert("]", at: edit.selection.upperBound)
            result.insert("[", at: edit.selection.location)
        }
        let after = result.replacingOccurrences(of: "‸", with: "").replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        #expect(MarkdownLexer().relexAll(text: after as NSString).tables.count == 1, "\(after)")
        return result as String
    }

    private func command(_ command: MarkdownTable.Command, _ text: String) -> String? {
        run(text) { $0.edit(command, at: $1, in: $2) }
    }

    @Test("the table is found from any of its lines, not from the lines around it")
    func tableContaining() {
        let text = "Před\n| a | b |\n| - | - |\n| c | d |\nPo" as NSString
        let lexer = MarkdownLexer()
        lexer.relexAll(text: text)
        for word in ["| a", "| -", "| d"] {
            #expect(lexer.table(containing: text.range(of: word).location, in: text)?.rows.count == 3)
        }
        #expect(lexer.table(containing: text.range(of: "Před").location, in: text) == nil)
        #expect(lexer.table(containing: text.range(of: "Po").location, in: text) == nil)
        #expect(lexer.table(containing: text.length - 2, in: text) == nil)
    }

    @Test("rows are added below or above with the table's column count")
    func insertRows() {
        #expect(command(.insertRowBelow, "| a | b |\n| - | - |\n| c‸ | d |\nPo") == "| a | b |\n| - | - |\n| c | d |\n| ‸ |  |\nPo")
        #expect(command(.insertRowAbove, "| a | b |\n| - | - |\n| c‸ | d |") == "| a | b |\n| - | - |\n| ‸ |  |\n| c | d |")
        // From the header, the new row goes below the delimiter row; nothing goes above the header.
        #expect(command(.insertRowBelow, "| a‸ | b |\n| - | - |\n| c | d |") == "| a | b |\n| - | - |\n| ‸ |  |\n| c | d |")
        #expect(command(.insertRowAbove, "| a‸ | b |\n| - | - |") == nil)
        // Indented tables keep their indentation.
        #expect(command(.insertRowBelow, "  a | b‸\n  --|--") == "  a | b\n  --|--\n  | ‸ |  |")
    }

    @Test("Enter adds an empty row below; on an empty last row it leaves the table")
    func enter() {
        let enter: (String) -> String? = { text in self.run(text) { $0.newline(at: $1, in: $2) } }
        #expect(enter("| a | b |\n| - | - |\n| c | d‸ |") == "| a | b |\n| - | - |\n| c | d |\n| ‸ |  |")
        #expect(enter("| a | b |\n| - | - |\n| c‸ | d |\n| e | f |") == "| a | b |\n| - | - |\n| c | d |\n| ‸ |  |\n| e | f |")
        #expect(enter("| a | b |‸\n| - | - |") == "| a | b |\n| - | - |\n| ‸ |  |")
        #expect(enter("| a | b |\n| - | - |\n| c | d |\n|  | ‸ |\nPo") == "| a | b |\n| - | - |\n| c | d |\n‸\nPo")
        #expect(enter("Před‸\n| a |\n| - |") == nil)
        #expect(enter("‸| a |\n| - |") == nil)
    }

    @Test("rows are deleted, never the header or the delimiter row")
    func deleteRows() {
        #expect(command(.deleteRow, "| a | b |\n| - | - |\n| c | d‸ |\n| e | f |") == "| a | b |\n| - | - |\n| e | ‸f |")
        #expect(command(.deleteRow, "| a | b |\n| - | - |\n| c | d |\n| e‸ | f |") == "| a | b |\n| - | - |\n| ‸c | d |")
        #expect(command(.deleteRow, "| a | b |\n| - | - |\n| c‸ | d |") == "| ‸a | b |\n| - | - |")
        #expect(command(.deleteRow, "| a‸ | b |\n| - | - |") == nil)
        #expect(command(.deleteRow, "| a | b |\n| -‸ | - |") == nil)
    }

    @Test("columns are added left or right, with a delimiter cell, keeping the alignments")
    func insertColumns() {
        let table = "| a | b |\n| :- | -: |\n| c‸ | d |"
        #expect(command(.insertColumnRight, table) == "| a |  | b |\n| :- | --- | -: |\n| c | ‸ | d |")
        #expect(command(.insertColumnLeft, table) == "|  | a | b |\n| --- | :- | -: |\n| ‸ | c | d |")
        // Rows without outer pipes, short rows and escaped pipes come out valid.
        #expect(command(.insertColumnRight, "a | b‸\n--|--\nc |\n\\| | x") == "| a | b | ‸ |\n| -- | -- | --- |\n| c |  |  |\n| \\| | x |  |")
    }

    @Test("columns are deleted, never the only one")
    func deleteColumns() {
        let table = "| a | b | c |\n| :- | :-: | -: |\n| d | e‸ | f |"
        #expect(command(.deleteColumn, table) == "| a | c |\n| :- | -: |\n| d | ‸f |")
        #expect(command(.deleteColumn, "| a | b‸ |\n| - | - |") == "| ‸a |\n| - |")
        #expect(command(.deleteColumn, "| a‸ |\n| - |") == nil)
    }

    @Test("Tab selects the next cell's text, skipping the delimiter row, and adds a row at the end")
    func tab() {
        let tab: (String, Bool) -> String? = { text, forward in self.run(text) { $0.moveToCell(from: $1, forward: forward, in: $2) } }
        #expect(tab("| a‸ | bb |\n| - | - |\n| c |  |", true) == "| a | [bb] |\n| - | - |\n| c |  |")
        #expect(tab("| a | bb‸ |\n| - | - |\n| c |  |", true) == "| a | bb |\n| - | - |\n| [c] |  |")
        #expect(tab("| a | bb |\n| - | - |\n| c‸ |  |", true) == "| a | bb |\n| - | - |\n| c | ‸ |")
        #expect(tab("| a | bb |\n| - | - |\n| c | ‸ |", true) == "| a | bb |\n| - | - |\n| c |  |\n| ‸ |  |")
        #expect(tab("| a | bb |\n| - | - |\n| c‸ |  |", false) == "| a | [bb] |\n| - | - |\n| c |  |")
        #expect(tab("| a‸ | bb |\n| - | - |", false) == nil)
    }
}
