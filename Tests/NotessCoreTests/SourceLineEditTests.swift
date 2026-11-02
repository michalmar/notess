import Foundation
import NotessCore
import Testing

@Suite("Literal source-line transformations")
struct SourceLineEditTests {
    @Test("line boundaries retain separators without joining text or adding unrelated blank lines", arguments: [
        (.moveUp, "a\nb", 3, 0, "b\na", 1, 0),
        (.moveDown, "a\nb", 1, 0, "b\na", 3, 0),
        (.moveUp, "a\nb\n", 3, 0, "b\na\n", 1, 0),
        (.moveDown, "a\nb\n", 1, 0, "b\na\n", 3, 0),
        (.moveUp, "a\n", 2, 0, "\na", 0, 0),
        (.moveDown, "a\n", 1, 0, "\na", 2, 0),
        (.moveUp, "a\n\nb", 2, 0, "\na\nb", 0, 0),
        (.moveDown, "a\n\nb", 2, 0, "a\nb\n", 4, 0),
        (.duplicateAbove, "", 0, 0, "\n", 0, 0),
        (.duplicateBelow, "", 0, 0, "\n", 1, 0),
        (.duplicateAbove, "a", 1, 0, "a\na", 1, 0),
        (.duplicateBelow, "a", 1, 0, "a\na", 3, 0),
        (.duplicateAbove, "a\n", 2, 0, "a\n\n", 2, 0),
        (.duplicateBelow, "a\n", 2, 0, "a\n\n", 3, 0),
        (.duplicateBelow, "a\n\nb", 2, 0, "a\n\n\nb", 3, 0),
        (.duplicateBelow, "a\nb\nc", 2, 2, "a\nb\nb\nc", 4, 2),
        (.duplicateAbove, "a\nb\nc", 2, 2, "a\nb\nb\nc", 2, 2),
        (.moveUp, "a\n🙂 e\u{301}\nz", 5, 2, "🙂 e\u{301}\na\nz", 3, 2),
        (.moveDown, "a\r\nb\r\nc", 4, 0, "a\r\nc\r\nb", 7, 0),
        (.duplicateBelow, "a\r\nb", 4, 0, "a\r\nb\r\nb", 7, 0),
    ] as [(SourceLineEdit.Command, String, Int, Int, String, Int, Int)])
    func boundaries(command: SourceLineEdit.Command, source: String, start: Int, length: Int,
                    expected: String, expectedStart: Int, expectedLength: Int) throws {
        let selection = NSRange(location: start, length: length)
        #expect(SourceLineEdit.canApply(command, in: source, selection: selection))
        let edit = try #require(SourceLineEdit.edit(command, in: source, selection: selection))
        #expect((source as NSString).replacingCharacters(in: edit.range, with: edit.replacement) == expected)
        #expect(edit.selection == NSRange(location: expectedStart, length: expectedLength))
    }

    @Test("a move cannot wrap beyond the note's first or final source line", arguments: [
        (.moveUp, "", 0), (.moveDown, "", 0),
        (.moveUp, "a\nb", 0), (.moveDown, "a\nb", 3),
        (.moveDown, "a\n", 2),
    ] as [(SourceLineEdit.Command, String, Int)])
    func boundariesAreNoOps(command: SourceLineEdit.Command, source: String, caret: Int) {
        let selection = NSRange(location: caret, length: 0)
        #expect(!SourceLineEdit.canApply(command, in: source, selection: selection))
        #expect(SourceLineEdit.edit(command, in: source, selection: selection) == nil)
    }
}
