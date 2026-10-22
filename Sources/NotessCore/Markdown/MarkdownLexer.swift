import Foundation

/// Incremental Markdown lexer for the live-formatting editor.
///
/// It remembers where every line starts and the block state at the start of
/// each line (inside a code fence, a table, front matter, …). After an edit
/// only the changed lines (plus the line before, whose meaning can depend on
/// the next one) are re-lexed, continuing past them only while the block state
/// differs from what was stored. Typing in a paragraph therefore costs a couple
/// of lines, whatever the size of the note; opening a code fence re-lexes until
/// the state converges again.
///
/// The lexer does not own the text: callers pass the current text with every
/// call and must report every edit.
public final class MarkdownLexer {
    /// The line-aligned range that must be restyled after an edit, and all
    /// tokens, tables and list lines inside it. A table is always complete:
    /// an edit anywhere in a table restyles the whole table, since every row's
    /// layout depends on the widest cell of each column.
    public struct Update: Equatable, Sendable {
        public var range: NSRange
        public var tokens: [MarkdownToken]
        public var tables: [MarkdownTable]
        public var listLines: [MarkdownListLine] = []
    }

    /// UTF-16 offset of the first character of every line.
    private(set) var lineStarts: [Int] = [0]
    /// Block state at the start of every line.
    private(set) var states: [MarkdownLineState] = [.documentStart]
    /// Every list line's level and marker digits, nil for other lines.
    private var listLines: [ListLineInfo?] = [nil]

    private struct ListLineInfo {
        var level: Int
        var digits: Int
        /// The `MarkdownListLine.markerDigits` the line was last reported with.
        var markerDigits: [Int]
    }

    public init() {}

    public var lineCount: Int { lineStarts.count }

    /// Lexes the whole text from scratch and returns all tokens.
    @discardableResult
    public func reset(text: NSString) -> [MarkdownToken] {
        relexAll(text: text).tokens
    }

    /// Lexes the whole text from scratch; the update covers all of it.
    @discardableResult
    public func relexAll(text: NSString) -> Update {
        lineStarts = [0] + Self.lineStarts(in: text, from: 0, to: text.length)
        states = Array(repeating: .documentStart, count: lineStarts.count)
        listLines = Array(repeating: nil, count: lineStarts.count)
        return relex(text, from: 0, through: lineStarts.count - 1)
    }

    /// Updates the lexer after `text` was edited, using the values reported by
    /// `NSTextStorage` (`editedRange` in the new text, `changeInLength`).
    public func update(text: NSString, editedRange: NSRange, changeInLength delta: Int) -> Update {
        let location = editedRange.location
        let oldEnd = location + editedRange.length - delta
        guard location >= 0, oldEnd >= location, editedRange.upperBound <= text.length else {
            return relexAll(text: text)
        }

        // A line starts after a newline. Newlines before the edit stay put,
        // newlines inside the old edited range are gone, newlines after it shift.
        let firstRemoved = Self.upperBound(lineStarts, location)
        let firstShifted = Self.upperBound(lineStarts, oldEnd)
        let inserted = Self.lineStarts(in: text, from: location, to: editedRange.upperBound)
        lineStarts.replaceSubrange(firstRemoved..<firstShifted, with: inserted)
        states.replaceSubrange(firstRemoved..<firstShifted, with: repeatElement(.documentStart, count: inserted.count))
        listLines.replaceSubrange(firstRemoved..<firstShifted, with: repeatElement(nil, count: inserted.count))
        if delta != 0 {
            for index in (firstRemoved + inserted.count)..<lineStarts.count {
                lineStarts[index] += delta
            }
        }

        let firstEdited = firstRemoved - 1
        let lastEdited = firstEdited + inserted.count
        // An edit in a table, or on the line right below it, starts at the header.
        var first = max(0, firstEdited - 1)
        if states[firstEdited].table != .none {
            while first > 0 && states[first].table != .none { first -= 1 }
        }
        return relex(text, from: first, through: lastEdited)
    }

    /// The change that toggles the task box at `index`, or nil when `index` is
    /// not inside a `[ ]`/`[x]` box. Only the text changes; nothing is saved.
    public func taskToggle(at index: Int, in text: NSString) -> (range: NSRange, replacement: String)? {
        guard index >= 0, index < text.length else { return nil }
        let lexer = lexed(Self.upperBound(lineStarts, index) - 1, in: text)
        for token in lexer.tokens {
            guard case .task(let isChecked) = token.kind, NSLocationInRange(index, token.range) else { continue }
            return (NSRange(location: token.range.location + 1, length: 1), isChecked ? " " : "x")
        }
        return nil
    }

    /// What Enter does with a collapsed caret at `caret`: continue the list
    /// or end it (see `MarkdownListLine`). Nil unless the caret is at the end
    /// of a list item's marker line outside block quotes, or when the next
    /// number would be too long. Uses the stored block states; changes nothing.
    public func listNewline(at caret: Int, in text: NSString) -> MarkdownListLine.Edit? {
        guard caret >= 0, caret <= text.length else { return nil }
        let line = Self.upperBound(lineStarts, caret) - 1
        guard line >= 0, line < states.count else { return nil }
        guard let item = lexed(line, in: text).listLine, caret == item.range.upperBound else { return nil }
        return item.newline(in: text)
    }

    /// The Tag completion context for a collapsed caret at `caret`, or nil
    /// when the caret does not follow `#` and at least one Tag-name character
    /// in a place where Tags are recognised. Uses the stored block states;
    /// changes nothing.
    public func tagCompletionContext(at caret: Int, in text: NSString) -> TagCompletionContext? {
        guard caret > 1, caret <= text.length else { return nil }
        if caret < text.length, UTF16.isTrailSurrogate(text.character(at: caret)),
           UTF16.isLeadSurrogate(text.character(at: caret - 1)) { return nil }
        let line = Self.upperBound(lineStarts, caret) - 1
        guard line >= 0, line < states.count else { return nil }
        for token in lexed(line, in: text, recognizesTagPrefixes: true).tokens where token.kind == .tag {
            guard caret > token.range.location + 1, caret <= NSMaxRange(token.range) else { continue }
            let prefix = text.substring(with: NSRange(location: token.range.location + 1, length: caret - token.range.location - 1))
            return TagCompletionContext(prefix: prefix, tokenRange: token.range, caret: caret)
        }
        return nil
    }

    /// The table with a row on the line of `index` (`index` may be the end of
    /// the text), or nil. Uses the stored block states; changes nothing.
    public func table(containing index: Int, in text: NSString) -> MarkdownTable? {
        guard index >= 0, index <= text.length else { return nil }
        let target = Self.upperBound(lineStarts, index) - 1
        var line = target
        while line > 0 && states[line].table != .none { line -= 1 }
        var tables: [MarkdownTable] = []
        var state = states[line]
        while line < lineStarts.count {
            var lexer = MarkdownLineLexer(line: lineUnits(line, in: text), offset: lineStarts[line])
            let current = line
            state = lexer.lex(state: state, isFirstLine: line == 0) { nextLineUnits(after: current, in: text) }
            guard let row = lexer.tableRow else {
                if line >= target { break }
                tables.removeAll()
                line += 1
                continue
            }
            if row.kind == .header && line > target { break }
            Self.add(row, alignments: lexer.tableAlignments, to: &tables)
            line += 1
            if line > target && state.table == .none { break }
        }
        guard let table = tables.last, line > target, table.rows.count > 1 else { return nil }
        return table
    }

    // MARK: Lexing

    /// `line` lexed with its stored block state; changes nothing.
    private func lexed(_ line: Int, in text: NSString, recognizesTagPrefixes: Bool = false) -> MarkdownLineLexer {
        var lexer = MarkdownLineLexer(line: lineUnits(line, in: text), offset: lineStarts[line], recognizesTagPrefixes: recognizesTagPrefixes)
        _ = lexer.lex(state: states[line], isFirstLine: line == 0) { nextLineUnits(after: line, in: text) }
        return lexer
    }

    /// Re-lexes from `first` through at least `last`, and on through whole
    /// lists whose widest numbers changed, since every line of a list is laid
    /// out with room for them.
    private func relex(_ text: NSString, from first: Int, through last: Int) -> Update {
        var (update, lexed) = lex(text, from: first, through: last)
        let lists = listExtent(around: lexed)
        let digits = ListDigits(lines: lists, states: states, listLines: listLines)
        let stale = lists.contains { line in
            guard !lexed.contains(line), let info = listLines[line] else { return false }
            return !digits.matches(info.markerDigits, line: line, level: info.level)
        }
        if stale {
            (update, lexed) = lex(text, from: min(first, lists.lowerBound), through: max(lexed.upperBound, lists.upperBound) - 1)
        }
        var line = lexed.lowerBound
        for index in update.listLines.indices {
            while lineStarts[line] != update.listLines[index].range.location { line += 1 }
            let markerDigits = digits.markerDigits(line: line, level: update.listLines[index].level)
            update.listLines[index].markerDigits = markerDigits
            listLines[line]?.markerDigits = markerDigits
            line += 1
        }
        return update
    }

    /// Lexes from `first` until the block state converges after `last`.
    /// Returns the update and the lines lexed.
    private func lex(_ text: NSString, from first: Int, through last: Int) -> (Update, Range<Int>) {
        var tokens: [MarkdownToken] = []
        var tables: [MarkdownTable] = []
        var listLines: [MarkdownListLine] = []
        var state = states[first]
        var line = first
        while line < lineStarts.count {
            states[line] = state
            var lexer = MarkdownLineLexer(line: lineUnits(line, in: text), offset: lineStarts[line])
            let current = line
            let next = lexer.lex(state: state, isFirstLine: line == 0) { nextLineUnits(after: current, in: text) }
            tokens.append(contentsOf: lexer.tokens)
            self.listLines[line] = lexer.listLine.map { ListLineInfo(level: $0.level, digits: $0.digits, markerDigits: []) }
            if let listLine = lexer.listLine { listLines.append(listLine) }
            if let row = lexer.tableRow {
                Self.add(row, alignments: lexer.tableAlignments, to: &tables)
            }
            line += 1
            // Never stop inside a table, so it is always restyled whole.
            if line < lineStarts.count && line > last && next == states[line] && next.table == .none { break }
            state = next
        }
        let start = lineStarts[first]
        let end = line < lineStarts.count ? lineStarts[line] : text.length
        let update = Update(range: NSRange(location: start, length: end - start), tokens: tokens, tables: tables, listLines: listLines)
        return (update, first..<line)
    }

    /// `lines` widened to the whole lists they touch: a list runs from its
    /// first item to the last line whose block state is still in it.
    private func listExtent(around lines: Range<Int>) -> Range<Int> {
        var start = lines.lowerBound
        while start > 0 && !states[start].list.isEmpty { start -= 1 }
        var end = lines.upperBound
        while end < lineStarts.count && !states[end].list.isEmpty { end += 1 }
        return start..<end
    }

    /// The most marker digits at every level of each list in some lines.
    private struct ListDigits {
        /// The first line of each list, ascending.
        private var starts: [Int] = []
        private var digits: [[Int]] = []

        init(lines: Range<Int>, states: [MarkdownLineState], listLines: [ListLineInfo?]) {
            for line in lines {
                if starts.isEmpty || states[line].list.isEmpty {
                    starts.append(line)
                    digits.append([])
                }
                guard let info = listLines[line] else { continue }
                let list = digits.count - 1
                if digits[list].count <= info.level {
                    digits[list] += repeatElement(0, count: info.level + 1 - digits[list].count)
                }
                digits[list][info.level] = max(digits[list][info.level], info.digits)
            }
        }

        /// The `MarkdownListLine.markerDigits` of a list line at `level`.
        func markerDigits(line: Int, level: Int) -> [Int] {
            let list = self.list(of: line)
            return (0...level).map { $0 < list.count ? list[$0] : 0 }
        }

        func matches(_ markerDigits: [Int], line: Int, level: Int) -> Bool {
            let list = self.list(of: line)
            return markerDigits.count == level + 1
                && markerDigits.indices.allSatisfy { markerDigits[$0] == ($0 < list.count ? list[$0] : 0) }
        }

        private func list(of line: Int) -> [Int] {
            let index = MarkdownLexer.upperBound(starts, line) - 1
            return index >= 0 ? digits[index] : []
        }
    }

    /// A header row starts a new table; the other rows (and the delimiter
    /// row's alignments) go to the last one.
    private static func add(_ row: MarkdownTable.Row, alignments: [MarkdownTable.Alignment]?, to tables: inout [MarkdownTable]) {
        if row.kind == .header {
            tables.append(MarkdownTable(rows: [row], alignments: []))
        } else if !tables.isEmpty {
            tables[tables.count - 1].rows.append(row)
            if let alignments { tables[tables.count - 1].alignments = alignments }
        }
    }

    private func nextLineUnits(after line: Int, in text: NSString) -> [UInt16]? {
        line + 1 < lineStarts.count ? lineUnits(line + 1, in: text) : nil
    }

    /// The characters of `line` without its line break.
    private func lineUnits(_ line: Int, in text: NSString) -> [UInt16] {
        let start = lineStarts[line]
        var end = line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : text.length
        if end > start && text.character(at: end - 1) == Char.cr { end -= 1 }
        guard end > start else { return [] }
        var units = [UInt16](repeating: 0, count: end - start)
        text.getCharacters(&units, range: NSRange(location: start, length: end - start))
        return units
    }

    /// Offsets just after every `\n` in `start..<end`.
    private static func lineStarts(in text: NSString, from start: Int, to end: Int) -> [Int] {
        guard end > start else { return [] }
        var units = [UInt16](repeating: 0, count: end - start)
        text.getCharacters(&units, range: NSRange(location: start, length: end - start))
        var result: [Int] = []
        for (index, unit) in units.enumerated() where unit == Char.lf {
            result.append(start + index + 1)
        }
        return result
    }

    /// Index of the first element greater than `value` in the sorted `array`.
    private static func upperBound(_ array: [Int], _ value: Int) -> Int {
        var low = 0
        var high = array.count
        while low < high {
            let mid = (low + high) / 2
            if array[mid] <= value { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
