import AppKit
import NotessCore

/// Lines up the columns of a GFM table without changing its text.
///
/// Every cell is measured with its current formatting; then each cell that is
/// narrower than its column gets extra space (`.kern`) after its last
/// character, so the `|` after it moves to the column's edge. Right- and
/// centre-aligned columns put some or all of that space after the pipe before
/// the cell instead. The pipes stay visible and act as the column borders.
@MainActor
enum TableLayout {
    static func alignColumns(of table: MarkdownTable, in storage: NSTextStorage, pipeFont: NSFont) {
        let string = storage.mutableString
        // Plain pipes in every row, also the bold header, so the borders look alike.
        for pipe in table.rows.flatMap(\.pipes) {
            storage.addAttribute(.font, value: pipeFont, range: NSRange(location: pipe, length: 1))
        }

        struct Measured {
            var row: MarkdownTable.Row
            /// From the line start to the first cell: indentation and an optional leading pipe.
            var prefix: CGFloat
            var cells: [CGFloat]
            /// The width of the pipe after each cell, 0 when there is none.
            var closingPipes: [CGFloat]
        }
        let rows = table.rows.map { row in
            let lineStart = string.lineRange(for: NSRange(location: row.range.location, length: 0)).location
            let pipes = Set(row.pipes)
            return Measured(
                row: row,
                prefix: width(of: NSRange(location: lineStart, length: row.cells[0].location - lineStart), in: storage),
                cells: row.cells.map { width(of: $0, in: storage) },
                closingPipes: row.cells.map {
                    pipes.contains($0.upperBound) ? width(of: NSRange(location: $0.upperBound, length: 1), in: storage) : 0
                }
            )
        }

        // Where each row's cell starts, and where every column's closing pipe goes.
        var starts = rows.map(\.prefix)
        var kerns: [NSRange: CGFloat] = [:]
        let columnCount = rows.map(\.cells.count).max() ?? 0
        for column in 0..<columnCount {
            let edge = rows.indices.reduce(0) { result, index in
                guard column < rows[index].cells.count else { return result }
                return max(result, starts[index] + rows[index].cells[column])
            }
            for (index, measured) in rows.enumerated() where column < measured.cells.count {
                let row = measured.row
                let cell = row.cells[column]
                let padding = edge - starts[index] - measured.cells[column]
                starts[index] = edge + measured.closingPipes[column]
                guard padding > 0.01 else { continue }
                let hasOpeningPipe = row.pipes.contains(cell.location - 1)
                var leading: CGFloat = 0
                if hasOpeningPipe, row.kind != .delimiter, column < table.alignments.count {
                    switch table.alignments[column] {
                    case .left: leading = 0
                    case .center: leading = (padding / 2).rounded()
                    case .right: leading = padding
                    }
                }
                if leading > 0 {
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
    }

    /// The typographic width of `range` with its current attributes, trailing spaces included.
    private static func width(of range: NSRange, in storage: NSTextStorage) -> CGFloat {
        guard range.length > 0 else { return 0 }
        let line = CTLineCreateWithAttributedString(storage.attributedSubstring(from: range))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}
