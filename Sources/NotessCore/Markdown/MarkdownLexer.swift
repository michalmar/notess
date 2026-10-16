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
    /// tokens and tables inside it. A table is always complete: an edit
    /// anywhere in a table restyles the whole table, since every row's layout
    /// depends on the widest cell of each column.
    public struct Update: Equatable, Sendable {
        public var range: NSRange
        public var tokens: [MarkdownToken]
        public var tables: [MarkdownTable]
    }

    /// UTF-16 offset of the first character of every line.
    private(set) var lineStarts: [Int] = [0]
    /// Block state at the start of every line.
    private(set) var states: [MarkdownLineState] = [.documentStart]

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
        if delta != 0 {
            for index in (firstRemoved + inserted.count)..<lineStarts.count {
                lineStarts[index] += delta
            }
        }

        let firstEdited = firstRemoved - 1
        let lastEdited = firstEdited + inserted.count
        // Start at the header of a table the edit is in or below.
        var first = max(0, firstEdited - 1)
        while first > 0 && states[first].table != .none { first -= 1 }
        return relex(text, from: first, through: lastEdited)
    }

    /// The change that toggles the task box at `index`, or nil when `index` is
    /// not inside a `[ ]`/`[x]` box. Only the text changes; nothing is saved.
    public func taskToggle(at index: Int, in text: NSString) -> (range: NSRange, replacement: String)? {
        guard index >= 0, index < text.length else { return nil }
        let line = Self.upperBound(lineStarts, index) - 1
        var lexer = MarkdownLineLexer(line: lineUnits(line, in: text), offset: lineStarts[line])
        _ = lexer.lex(state: states[line], isFirstLine: line == 0) { nextLineUnits(after: line, in: text) }
        for token in lexer.tokens {
            guard case .task(let isChecked) = token.kind, NSLocationInRange(index, token.range) else { continue }
            return (NSRange(location: token.range.location + 1, length: 1), isChecked ? " " : "x")
        }
        return nil
    }

    // MARK: Lexing

    private func relex(_ text: NSString, from first: Int, through last: Int) -> Update {
        var tokens: [MarkdownToken] = []
        var tables: [MarkdownTable] = []
        var state = states[first]
        var line = first
        while line < lineStarts.count {
            states[line] = state
            var lexer = MarkdownLineLexer(line: lineUnits(line, in: text), offset: lineStarts[line])
            let current = line
            let next = lexer.lex(state: state, isFirstLine: line == 0) { nextLineUnits(after: current, in: text) }
            tokens.append(contentsOf: lexer.tokens)
            if let row = lexer.tableRow {
                if row.kind == .header {
                    tables.append(MarkdownTable(rows: [row], alignments: []))
                } else if !tables.isEmpty {
                    tables[tables.count - 1].rows.append(row)
                    if let alignments = lexer.tableAlignments {
                        tables[tables.count - 1].alignments = alignments
                    }
                }
            }
            line += 1
            // Never stop inside a table, so it is always restyled whole.
            if line < lineStarts.count && line > last && next == states[line] && next.table == .none { break }
            state = next
        }
        let start = lineStarts[first]
        let end = line < lineStarts.count ? lineStarts[line] : text.length
        return Update(range: NSRange(location: start, length: end - start), tokens: tokens, tables: tables)
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
