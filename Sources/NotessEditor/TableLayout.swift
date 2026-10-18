import AppKit
import NotessCore

extension NSAttributedString.Key {
    /// A `TableRowDecoration` on every line of a GFM table.
    static let notessTableRow = NSAttributedString.Key("NotessTableRow")
}

/// Shows a GFM table as a table without changing its text.
///
/// Every cell is measured with its current formatting; then each cell that is
/// narrower than its column gets extra space (`.kern`) after its last
/// character, so the `|` after it moves to the column's edge. Right- and
/// centre-aligned columns put some or all of that space after the pipe before
/// the cell instead (or, in a row without an opening pipe, as the row's first-line
/// indent). The pipes and the delimiter row are hidden (the delimiter
/// row is also squeezed to a hairline); `TableRowLayoutFragment` draws the grid
/// from the `TableRowDecoration` set on every row. The delimiter row stays
/// visible while `selection` touches it, so it can be edited.
///
/// Returns the line of the delimiter row left visible, if any.
@MainActor
enum TableLayout {
    static func layOut(
        _ table: MarkdownTable,
        in storage: NSTextStorage,
        style: MarkdownEditorStyle,
        showingDelimiterRowAt selection: NSRange?
    ) -> NSRange? {
        let string = storage.mutableString
        let pipeFont = style.font
        let hidden = NSColor.clear
        // Each pipe takes its own width plus this much: room around the grid line.
        let pipeWidth = width(of: "|", font: pipeFont) + cellPadding
        // Plain pipes in every row, also the bold header, so the columns are alike.
        for pipe in table.rows.flatMap(\.pipes) {
            storage.addAttributes([.font: pipeFont, .foregroundColor: hidden], range: NSRange(location: pipe, length: 1))
        }

        struct Measured {
            var row: MarkdownTable.Row
            /// From the line start to the first cell: indentation and an optional leading pipe.
            var prefix: CGFloat
            var cells: [CGFloat]
            /// The width of the pipe after each cell, 0 when there is none.
            var closingPipes: [CGFloat]
        }
        // The hidden delimiter row neither sets nor follows the column widths.
        let rows = table.rows.filter { $0.kind != .delimiter }.map { row in
            let lineStart = string.lineRange(for: NSRange(location: row.range.location, length: 0)).location
            let pipes = Set(row.pipes)
            return Measured(
                row: row,
                prefix: width(of: NSRange(location: lineStart, length: row.cells[0].location - lineStart), in: storage)
                    + (pipes.contains(row.cells[0].location - 1) ? cellPadding : 0),
                cells: row.cells.map { width(of: $0, in: storage) },
                closingPipes: row.cells.map { pipes.contains($0.upperBound) ? pipeWidth : 0 }
            )
        }

        // Where each row's cell starts, and where every column's closing pipe goes.
        var starts = rows.map(\.prefix)
        var edges: [CGFloat] = []
        var kerns: [NSRange: CGFloat] = [:]
        var indents: [Int: CGFloat] = [:]
        for row in table.rows where row.kind != .delimiter {
            for pipe in row.pipes {
                kerns[NSRange(location: pipe, length: 1)] = cellPadding
            }
        }
        let columnCount = rows.map(\.cells.count).max() ?? 0
        for column in 0..<columnCount {
            let edge = rows.indices.reduce(0) { result, index in
                guard column < rows[index].cells.count else { return result }
                return max(result, starts[index] + rows[index].cells[column])
            }
            edges.append(edge)
            for (index, measured) in rows.enumerated() where column < measured.cells.count {
                let row = measured.row
                let cell = row.cells[column]
                let padding = edge - starts[index] - measured.cells[column]
                starts[index] = edge + measured.closingPipes[column]
                guard padding > 0.01 else { continue }
                var leading: CGFloat = 0
                if column < table.alignments.count {
                    switch table.alignments[column] {
                    case .left: leading = 0
                    case .center: leading = (padding / 2).rounded()
                    case .right: leading = padding
                    }
                }
                if leading > 0, !row.pipes.contains(cell.location - 1) {
                    // No opening pipe to carry the space: indent the row's first line instead.
                    indents[row.range.location] = leading
                } else if leading > 0 {
                    kerns[NSRange(location: cell.location - 1, length: 1), default: 0] += leading
                }
                // Without a closing pipe nothing follows the cell that needs to line up.
                guard measured.closingPipes[column] > 0, padding - leading > 0.01 else { continue }
                let last = cell.length > 0
                    ? string.rangeOfComposedCharacterSequence(at: cell.upperBound - 1)
                    : NSRange(location: cell.location - 1, length: 1)
                guard last.location >= 0 else { continue }
                kerns[last, default: 0] += padding - leading
            }
        }
        for (range, kern) in kerns {
            storage.addAttribute(.kern, value: kern, range: range)
        }

        guard let header = rows.first else { return nil }
        let lines = gridLines(header: header.row, prefix: header.prefix, edges: edges, pipeWidth: pipeWidth)
        let rowStyle = NSMutableParagraphStyle()
        rowStyle.paragraphSpacingBefore = rowPadding
        rowStyle.paragraphSpacing = rowPadding
        let delimiterStyle = NSMutableParagraphStyle()
        delimiterStyle.minimumLineHeight = 1
        delimiterStyle.maximumLineHeight = 1
        var shownDelimiterRow: NSRange?
        for row in table.rows {
            let line = string.lineRange(for: NSRange(location: row.range.location, length: 0))
            if row.kind == .delimiter, let selection, self.selection(selection, touches: line, in: string) {
                storage.addAttribute(.foregroundColor, value: style.colors.syntaxMarker, range: line)
                shownDelimiterRow = line
                continue
            }
            let decoration = TableRowDecoration(
                kind: row.kind,
                columnLines: lines,
                border: style.colors.tableBorder,
                headerBackground: style.colors.tableHeaderBackground
            )
            storage.addAttribute(.notessTableRow, value: decoration, range: line)
            if row.kind == .delimiter {
                storage.addAttributes([.foregroundColor: hidden, .paragraphStyle: delimiterStyle], range: line)
            } else {
                var style = rowStyle
                if let indent = indents[row.range.location] {
                    style = rowStyle.mutableCopy() as! NSMutableParagraphStyle
                    style.firstLineHeadIndent = indent
                }
                storage.addAttribute(.paragraphStyle, value: style, range: line)
            }
        }
        return shownDelimiterRow
    }

    /// Whether `selection` is on `line`, its end included but not the next line's start.
    static func selection(_ selection: NSRange, touches line: NSRange, in string: NSString) -> Bool {
        var end = min(line.upperBound, string.length)
        while end > line.location, let scalar = UnicodeScalar(string.character(at: end - 1)),
              CharacterSet.newlines.contains(scalar) {
            end -= 1
        }
        return selection.location <= end && selection.upperBound >= line.location
    }

    /// Space around the text of a cell, on each side of a grid line and above and below a row.
    nonisolated static let cellPadding: CGFloat = 6
    /// Space above and below the text of a row, inside its rules.
    nonisolated static let rowPadding: CGFloat = cellPadding / 2

    /// The x of every vertical line from the line start: through the middle
    /// of each pipe, or just outside the text where the header has no outer pipe.
    private static func gridLines(header: MarkdownTable.Row, prefix: CGFloat, edges: [CGFloat], pipeWidth: CGFloat) -> [CGFloat] {
        guard let first = header.cells.first, let last = header.cells.last else { return [] }
        let half = pipeWidth / 2
        let left = header.pipes.contains(first.location - 1) ? prefix - half : prefix - cellPadding
        let right = header.pipes.contains(last.upperBound) ? edges[edges.count - 1] + half : edges[edges.count - 1] + cellPadding
        return [left] + edges.dropLast().map { $0 + half } + [right]
    }

    /// The typographic width of `range` with its current attributes, trailing spaces included.
    private static func width(of range: NSRange, in storage: NSTextStorage) -> CGFloat {
        guard range.length > 0 else { return 0 }
        return width(of: storage.attributedSubstring(from: range))
    }

    private static func width(of text: String, font: NSFont) -> CGFloat {
        width(of: NSAttributedString(string: text, attributes: [.font: font]))
    }

    private static func width(of text: NSAttributedString) -> CGFloat {
        let line = CTLineCreateWithAttributedString(text)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}
