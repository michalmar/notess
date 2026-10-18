import Foundation

/// Editing a GFM table as a table: rows and columns, Enter and Tab.
///
/// Every edit is one text replacement that keeps the table valid (the
/// delimiter row and its alignments included) plus the selection after it.
/// Row edits touch only the row's line. Column edits rewrite the table's rows
/// as `| a | b |`, since adding or removing a cell in a row without outer
/// pipes cannot always be done in place.
extension MarkdownTable {
    public enum Command: CaseIterable, Sendable {
        case insertRowAbove
        case insertRowBelow
        case insertColumnLeft
        case insertColumnRight
        case deleteRow
        case deleteColumn
    }

    /// A text change and the selection after it, both in UTF-16 offsets. A
    /// change that only moves the selection has an empty range and replacement.
    public struct Edit: Equatable, Sendable {
        public var range: NSRange
        public var replacement: String
        public var selection: NSRange

        public var changesText: Bool { range.length > 0 || !replacement.isEmpty }
    }

    /// The row (an index into `rows`) and the cell holding `index`.
    public struct Position: Equatable, Sendable {
        public var row: Int
        public var column: Int
    }

    /// The number of columns, set by the header (and its delimiter row).
    public var columnCount: Int { rows.first?.cells.count ?? 0 }

    /// Where `index` is in the table, nil when it is not on a row's line.
    public func position(of index: Int, in text: NSString) -> Position? {
        guard let row = rows.firstIndex(where: { NSLocationInRange(index, lineContent(of: $0, in: text)) || index == lineContent(of: $0, in: text).upperBound }) else {
            return nil
        }
        let cells = rows[row].cells
        let column = cells.firstIndex { index <= $0.upperBound } ?? max(0, cells.count - 1)
        return Position(row: row, column: column)
    }

    /// Where `command` would act at `index`, nil when it does not apply there
    /// (a row above the header, deleting the header, the only column, …).
    /// Uses only the table's metadata: no replacement text is built. `edit`
    /// and `applies` share it, so menu validation and execution cannot differ.
    private func target(of command: Command, at index: Int, in text: NSString) -> (position: Position, column: Int)? {
        guard let position = position(of: index, in: text) else { return nil }
        let kind = rows[position.row].kind
        switch command {
        case .insertRowAbove:
            guard kind != .header else { return nil }
        case .deleteRow:
            guard kind == .body else { return nil }
        case .deleteColumn:
            guard columnCount > 1 else { return nil }
        case .insertRowBelow, .insertColumnLeft, .insertColumnRight:
            break
        }
        // Cells past the header's width (a ragged row) count as its last column.
        return (position, min(position.column, columnCount - 1))
    }

    /// Whether `command` applies at `index`; `edit` is non-nil exactly then.
    public func applies(_ command: Command, at index: Int, in text: NSString) -> Bool {
        target(of: command, at: index, in: text) != nil
    }

    /// The edit `command` makes at `index`, nil when it does not apply there.
    public func edit(_ command: Command, at index: Int, in text: NSString) -> Edit? {
        guard let (position, column) = target(of: command, at: index, in: text) else { return nil }
        EditCounter.increment()
        switch command {
        case .insertRowAbove:
            return rows[position.row].kind == .delimiter
                ? insertingRow(below: 1, in: text)
                : insertingRow(above: position.row, in: text)
        case .insertRowBelow:
            return insertingRow(below: max(position.row, 1), in: text)
        case .insertColumnLeft:
            return insertingColumn(at: column, row: position.row, in: text)
        case .insertColumnRight:
            return insertingColumn(at: column + 1, row: position.row, in: text)
        case .deleteRow:
            return deletingRow(position.row, column: position.column, in: text)
        case .deleteColumn:
            return deletingColumn(column, row: position.row, in: text)
        }
    }

    /// How many edits `edit` has built on this thread, so tests can show that validation builds none.
    package static var editsBuiltCount: Int { EditCounter.value }

    /// What Enter does at `index`: a new empty row below the caret's row (below
    /// the delimiter row in the header), or, on an empty last row, leaving the
    /// table by emptying that row's line. Nil before the header's first
    /// character, where Enter opens a line above the table as usual.
    public func newline(at index: Int, in text: NSString) -> Edit? {
        guard let position = position(of: index, in: text) else { return nil }
        let row = rows[position.row]
        if row.kind == .header, index <= row.range.location { return nil }
        if row.kind == .body, position.row == rows.count - 1, row.cells.allSatisfy({ isBlank($0, in: text) }) {
            let start = lineStart(of: row, in: text)
            let range = NSRange(location: start, length: lineContent(of: row, in: text).upperBound - start)
            return Edit(range: range, replacement: "", selection: NSRange(location: start, length: 0))
        }
        return insertingRow(below: max(position.row, 1), in: text)
    }

    /// What Tab (or Shift+Tab, `forward` false) does at `index`: selects the
    /// text of the next (previous) cell, skipping the delimiter row. Tab in the
    /// last cell adds a row. Nil at the first cell going back.
    public func moveToCell(from index: Int, forward: Bool, in text: NSString) -> Edit? {
        guard let position = position(of: index, in: text) else { return nil }
        var row = position.row
        var column = position.column + (forward ? 1 : -1)
        while column < 0 || column >= rows[row].cells.count || rows[row].kind == .delimiter {
            row += forward ? 1 : -1
            if row < 0 { return nil }
            if row >= rows.count { return insertingRow(below: rows.count - 1, in: text) }
            column = forward ? 0 : rows[row].cells.count - 1
        }
        let selection = content(of: rows[row].cells[column], in: text)
        return Edit(range: NSRange(location: selection.location, length: 0), replacement: "", selection: selection)
    }

    // MARK: Rows

    private func insertingRow(below row: Int, in text: NSString) -> Edit {
        let end = lineContent(of: rows[row], in: text).upperBound
        let prefix = lineBreak(in: text) + indentation(in: text)
        return Edit(
            range: NSRange(location: end, length: 0),
            replacement: prefix + emptyRow,
            selection: NSRange(location: end + (prefix as NSString).length + 2, length: 0)
        )
    }

    private func insertingRow(above row: Int, in text: NSString) -> Edit {
        let start = lineStart(of: rows[row], in: text)
        let indentation = indentation(in: text)
        return Edit(
            range: NSRange(location: start, length: 0),
            replacement: indentation + emptyRow + lineBreak(in: text),
            selection: NSRange(location: start + (indentation as NSString).length + 2, length: 0)
        )
    }

    /// `|  |  |`: an empty cell is two spaces, the caret goes between them.
    private var emptyRow: String {
        "|" + Array(repeating: "  ", count: columnCount).joined(separator: "|") + "|"
    }

    private func deletingRow(_ row: Int, column: Int, in text: NSString) -> Edit {
        let line = text.lineRange(for: NSRange(location: rows[row].range.location, length: 0))
        var removed = line
        let isLastLine = line.upperBound == text.length && !text.substring(with: line).hasSuffix("\n")
        if isLastLine, line.location > 0 {
            // The last line goes with the line break before it.
            let breakLength = line.location > 1 && text.character(at: line.location - 2) == 0x0D ? 2 : 1
            removed = NSRange(location: line.location - breakLength, length: line.length + breakLength)
        }
        // The caret goes to the same column of the row taking its place, else the row above.
        let next = row + 1 < rows.count ? row + 1 : nil
        let target = next ?? (rows[row - 1].kind == .delimiter ? 0 : row - 1)
        let cells = rows[target].cells
        let cell = content(of: cells[min(column, cells.count - 1)], in: text)
        let shift = next == nil ? 0 : removed.length
        return Edit(range: removed, replacement: "", selection: NSRange(location: cell.location - shift, length: 0))
    }

    // MARK: Columns

    private func insertingColumn(at column: Int, row: Int, in text: NSString) -> Edit {
        rewritingColumns(in: text, caretRow: row, caretColumn: column) { cells, kind in
            cells.insert(kind == .delimiter ? "---" : "", at: column)
        }
    }

    private func deletingColumn(_ column: Int, row: Int, in text: NSString) -> Edit {
        return rewritingColumns(in: text, caretRow: row, caretColumn: min(column, columnCount - 2)) { cells, _ in
            if column < cells.count { cells.remove(at: column) }
        }
    }

    /// Rewrites every row as `| a | b |` after `change` edited its trimmed
    /// cells; rows shorter than the header are padded to its width first.
    private func rewritingColumns(
        in text: NSString,
        caretRow: Int,
        caretColumn: Int,
        change: (inout [String], Row.Kind) -> Void
    ) -> Edit {
        let indentation = indentation(in: text)
        let lineBreak = lineBreak(in: text)
        let start = lineStart(of: rows[0], in: text)
        let end = lineContent(of: rows[rows.count - 1], in: text).upperBound
        var replacement = ""
        var caret = start
        for (index, row) in rows.enumerated() {
            var cells = row.cells.map { text.substring(with: content(of: $0, in: text)) }
            if cells.count < columnCount { cells += Array(repeating: "", count: columnCount - cells.count) }
            if row.kind == .delimiter {
                cells = cells.map { $0.isEmpty ? "---" : $0 }
            }
            change(&cells, row.kind)
            if index > 0 { replacement += lineBreak }
            replacement += indentation
            var line = "|"
            for (column, cell) in cells.enumerated() {
                if index == caretRow && column == caretColumn {
                    caret = start + (replacement as NSString).length + (line as NSString).length + 1
                }
                line += " " + cell + " |"
            }
            replacement += line
        }
        return Edit(
            range: NSRange(location: start, length: end - start),
            replacement: replacement,
            selection: NSRange(location: caret, length: 0)
        )
    }

    // MARK: Text

    private func lineStart(of row: Row, in text: NSString) -> Int {
        text.lineRange(for: NSRange(location: row.range.location, length: 0)).location
    }

    /// The row's line without its line break, indentation and trailing spaces included.
    private func lineContent(of row: Row, in text: NSString) -> NSRange {
        var line = text.lineRange(for: NSRange(location: row.range.location, length: 0))
        while line.length > 0, [0x0A, 0x0D].contains(text.character(at: line.upperBound - 1)) {
            line.length -= 1
        }
        return line
    }

    /// The header's indentation, used for new and rewritten rows.
    private func indentation(in text: NSString) -> String {
        guard let header = rows.first else { return "" }
        let start = lineStart(of: header, in: text)
        return text.substring(with: NSRange(location: start, length: header.range.location - start))
    }

    /// The header line's line break, so new rows match a CRLF file.
    private func lineBreak(in text: NSString) -> String {
        guard let header = rows.first else { return "\n" }
        let end = lineContent(of: header, in: text).upperBound
        return end < text.length && text.character(at: end) == 0x0D ? "\r\n" : "\n"
    }

    /// A cell without its surrounding spaces; for a blank cell, the caret
    /// position after its first space.
    private func content(of cell: NSRange, in text: NSString) -> NSRange {
        var start = cell.location
        var end = cell.upperBound
        while start < end, Self.isSpace(text.character(at: start)) { start += 1 }
        while end > start, Self.isSpace(text.character(at: end - 1)) { end -= 1 }
        if start == end { return NSRange(location: cell.location + min(1, cell.length), length: 0) }
        return NSRange(location: start, length: end - start)
    }

    private func isBlank(_ cell: NSRange, in text: NSString) -> Bool {
        content(of: cell, in: text).length == 0
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09
    }
}

/// Counted per thread, so tests running in parallel do not see each other's edits.
private enum EditCounter {
    private static let key = "NotessCore.MarkdownTable.editsBuilt"

    static var value: Int { Thread.current.threadDictionary[key] as? Int ?? 0 }
    static func increment() { Thread.current.threadDictionary[key] = value + 1 }
}
