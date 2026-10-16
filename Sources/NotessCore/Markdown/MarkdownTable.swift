import Foundation

/// A GFM pipe table: its rows, the cells of every row and the column
/// alignments of its delimiter row, so the editor can line the columns up.
///
/// Ranges and offsets are UTF-16 offsets into the lexed text.
public struct MarkdownTable: Hashable, Sendable {
    public enum Alignment: Hashable, Sendable {
        /// `---` or `:---`.
        case left
        /// `:---:`.
        case center
        /// `---:`.
        case right
    }

    public struct Row: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case header
            /// The `| --- | :-: |` row below the header.
            case delimiter
            case body
        }

        public var kind: Kind
        /// From the row's first non-blank character to its last one.
        public var range: NSRange
        /// The text of every cell between its pipes (or the line's edge),
        /// surrounding spaces included. An optional leading pipe and a
        /// trailing pipe do not start a cell.
        public var cells: [NSRange]
        /// Offsets of the row's unescaped `|` characters.
        public var pipes: [Int]
    }

    public var rows: [Row]
    /// One per column of the delimiter row.
    public var alignments: [Alignment]

    /// From the start of the header row to the end of the last row, without
    /// its line break.
    public var range: NSRange {
        guard let first = rows.first?.range, let last = rows.last?.range else { return NSRange() }
        return NSRange(location: first.location, length: last.upperBound - first.location)
    }
}
