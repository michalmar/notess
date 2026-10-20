import Foundation

/// What one line of Markdown tells the lexer about the line after it.
///
/// The lexer stores the state at the start of every line so that after an edit
/// it can re-lex only the changed lines and stop as soon as the state at the
/// start of the next line matches the stored one again.
struct MarkdownLineState: Equatable, Sendable {
    struct Fence: Equatable, Sendable {
        var marker: UInt16
        var length: Int
    }

    enum Table: Equatable, Sendable {
        case none
        /// The previous line is a table header; this line is its delimiter row.
        case delimiterNext
        case body
    }

    var fence: Fence?
    var isFrontMatter = false
    var table: Table = .none
    /// The previous line is a setext heading; this line is its `===`/`---` underline.
    var isSetextUnderline = false
    var isInList = false
    var followsBlankLine = true
    var allowsIndentedCode = true

    static let documentStart = MarkdownLineState()
}

/// Lexes a single line of Markdown (block structure plus inline spans).
///
/// Works on UTF-16 code units so that token ranges are `NSString` offsets.
struct MarkdownLineLexer {
    private let c: [UInt16]
    private let offset: Int
    private(set) var tokens: [MarkdownToken] = []
    /// The line's cells when it is a row of a GFM table.
    private(set) var tableRow: MarkdownTable.Row?
    /// The column alignments when the line is a table's delimiter row.
    private(set) var tableAlignments: [MarkdownTable.Alignment]?
    /// Also emits `.tag` for names without a letter (`#2`, `#-`), so Tag
    /// completion can work on a prefix that is not yet a Tag. Never used for
    /// highlighting or Tag recognition.
    private let recognizesTagPrefixes: Bool

    init(line: [UInt16], offset: Int, recognizesTagPrefixes: Bool = false) {
        self.c = line
        self.offset = offset
        self.recognizesTagPrefixes = recognizesTagPrefixes
    }

    // MARK: Block structure

    /// Lexes the line and returns the state at the start of the next line.
    /// `nextLine` is only called when the line's meaning depends on it
    /// (table headers and setext headings).
    mutating func lex(
        state: MarkdownLineState,
        isFirstLine: Bool,
        nextLine: () -> [UInt16]?
    ) -> MarkdownLineState {
        var next = MarkdownLineState(isInList: state.isInList, followsBlankLine: false, allowsIndentedCode: false)
        let n = c.count

        if state.isFrontMatter {
            add(.frontMatter, 0, n)
            next.isFrontMatter = !(isExactly("---") || isExactly("..."))
            return next
        }
        if isFirstLine && isExactly("---") {
            add(.frontMatter, 0, n)
            next.isFrontMatter = true
            return next
        }
        if let fence = state.fence {
            if isClosingFence(fence) {
                add(.syntaxMarker, 0, n)
            } else {
                add(.codeBlock, 0, n)
                next.fence = fence
            }
            return next
        }

        let (indent, first) = indentation()
        if first == n {
            next.followsBlankLine = true
            next.allowsIndentedCode = true
            return next
        }
        if state.isSetextUnderline {
            add(.syntaxMarker, first, trimmedEnd())
            return next
        }
        if indent >= 4 && state.allowsIndentedCode && !state.isInList {
            add(.codeBlock, 0, n)
            next.allowsIndentedCode = true
            return next
        }
        if indent < 4 || state.isInList, let fence = openingFence(at: first) {
            add(.syntaxMarker, first, n)
            next.fence = fence
            return next
        }

        switch state.table {
        case .delimiterNext:
            add(.syntaxMarker, first, n)
            tableRow = makeTableRow(.delimiter, from: first)
            tableAlignments = tableRow?.cells.map(alignment(of:))
            next.table = .body
            return next
        case .body where containsUnescapedPipe(from: first):
            lexTableRow(from: first, isHeader: false)
            next.table = .body
            return next
        case .body, .none:
            break
        }

        if indent < 4 {
            if lexATXHeading(at: first) { return next }
            if isThematicBreak(from: first) {
                add(.thematicBreak, first, n)
                add(.syntaxMarker, first, trimmedEnd())
                return next
            }
            if c[first] == Char.gt {
                lexBlockquote(from: first)
                next.isInList = false
                return next
            }
        }
        if lexListItem(at: first) {
            next.isInList = true
            return next
        }

        // Paragraph line.
        if indent == 0 && state.followsBlankLine {
            next.isInList = false
        }
        if indent < 4, containsUnescapedPipe(from: first), let following = nextLine(),
           let columns = Self.delimiterRowColumns(following),
           columns == cellCount(from: first) {
            lexTableRow(from: first, isHeader: true)
            next.table = .delimiterNext
            return next
        }
        if indent < 4, !next.isInList, let following = nextLine(), let level = Self.setextLevel(following) {
            add(.heading(level: level), first, n)
            lexInline(first, n)
            next.isSetextUnderline = true
            return next
        }
        lexInline(first, n)
        return next
    }

    private mutating func add(_ kind: MarkdownToken.Kind, _ start: Int, _ end: Int) {
        guard end > start else { return }
        tokens.append(MarkdownToken(kind: kind, range: NSRange(location: offset + start, length: end - start)))
    }

    private func indentation() -> (columns: Int, first: Int) {
        var columns = 0
        var i = 0
        while i < c.count {
            if c[i] == Char.space {
                columns += 1
            } else if c[i] == Char.tab {
                columns += 4 - columns % 4
            } else {
                break
            }
            i += 1
        }
        return (columns, i)
    }

    private func trimmedEnd() -> Int {
        var end = c.count
        while end > 0 && Char.isWhitespace(c[end - 1]) { end -= 1 }
        return end
    }

    private func isExactly(_ string: String) -> Bool {
        Array(string.utf16) == Array(c[0..<trimmedEnd()])
    }

    private func openingFence(at first: Int) -> MarkdownLineState.Fence? {
        let marker = c[first]
        guard marker == Char.backtick || marker == Char.tilde else { return nil }
        var i = first
        while i < c.count && c[i] == marker { i += 1 }
        let length = i - first
        guard length >= 3 else { return nil }
        if marker == Char.backtick && c[i...].contains(Char.backtick) { return nil }
        return .init(marker: marker, length: length)
    }

    private func isClosingFence(_ fence: MarkdownLineState.Fence) -> Bool {
        var i = indentation().first
        let start = i
        while i < c.count && c[i] == fence.marker { i += 1 }
        guard i - start >= fence.length else { return false }
        return c[i...].allSatisfy(Char.isWhitespace)
    }

    private mutating func lexATXHeading(at first: Int) -> Bool {
        var i = first
        while i < c.count && c[i] == Char.hash { i += 1 }
        let level = i - first
        guard (1...6).contains(level), i == c.count || Char.isWhitespace(c[i]) else { return false }
        let n = c.count
        add(.heading(level: level), first, n)
        add(.syntaxMarker, first, i)

        var contentEnd = trimmedEnd()
        var closing = contentEnd
        while closing > i && c[closing - 1] == Char.hash { closing -= 1 }
        if closing < contentEnd && (closing == i || Char.isWhitespace(c[closing - 1])) {
            add(.syntaxMarker, closing, contentEnd)
            contentEnd = closing
        }
        lexInline(i, contentEnd)
        return true
    }

    private func isThematicBreak(from first: Int) -> Bool {
        let marker = c[first]
        guard marker == Char.star || marker == Char.dash || marker == Char.underscore else { return false }
        var count = 0
        for unit in c[first...] {
            if unit == marker {
                count += 1
            } else if !Char.isWhitespace(unit) {
                return false
            }
        }
        return count >= 3
    }

    private mutating func lexBlockquote(from first: Int) {
        add(.blockquote, first, c.count)
        var i = first
        while i < c.count && c[i] == Char.gt {
            var markerEnd = i + 1
            if markerEnd < c.count && Char.isWhitespace(c[markerEnd]) { markerEnd += 1 }
            add(.syntaxMarker, i, i + 1)
            i = markerEnd
            while i < c.count && c[i] == Char.space { i += 1 }
        }
        if i < c.count && !lexListItem(at: i) {
            lexInline(i, c.count)
        }
    }

    /// Recognises `- item`, `* item`, `+ item`, `1. item`, `1) item` and task
    /// items `- [ ] task` / `- [x] done`.
    private mutating func lexListItem(at first: Int) -> Bool {
        let n = c.count
        var markerEnd: Int
        if c[first] == Char.dash || c[first] == Char.star || c[first] == Char.plus {
            markerEnd = first + 1
        } else {
            var i = first
            while i < n && i - first < 9 && Char.isDigit(c[i]) { i += 1 }
            guard i > first, i < n, c[i] == Char.dot || c[i] == Char.rparen else { return false }
            markerEnd = i + 1
        }
        guard markerEnd == n || Char.isWhitespace(c[markerEnd]) else { return false }
        add(.listMarker, first, markerEnd)

        var content = markerEnd
        while content < n && Char.isWhitespace(c[content]) { content += 1 }
        if content + 2 < n, c[content] == Char.lbracket, c[content + 2] == Char.rbracket,
           content + 3 == n || Char.isWhitespace(c[content + 3]) {
            let mark = c[content + 1]
            if mark == Char.space || mark == Char.x || mark == Char.upperX {
                let checked = mark != Char.space
                add(.task(isChecked: checked), content, content + 3)
                var text = content + 3
                while text < n && Char.isWhitespace(c[text]) { text += 1 }
                if checked { add(.completedTask, text, n) }
                lexInline(text, n)
                return true
            }
        }
        lexInline(content, n)
        return true
    }

    // MARK: Tables

    private func containsUnescapedPipe(from start: Int) -> Bool {
        !pipePositions(from: start).isEmpty
    }

    private func pipePositions(from start: Int) -> [Int] {
        var result: [Int] = []
        var i = start
        while i < c.count {
            if c[i] == Char.backslash { i += 2; continue }
            if c[i] == Char.pipe { result.append(i) }
            i += 1
        }
        return result
    }

    private func cellCount(from first: Int) -> Int {
        let pipes = pipePositions(from: first)
        var count = pipes.count + 1
        if pipes.first == first { count -= 1 }
        if pipes.last == trimmedEnd() - 1 { count -= 1 }
        return count
    }

    private mutating func lexTableRow(from first: Int, isHeader: Bool) {
        if isHeader { add(.tableHeader, first, c.count) }
        tableRow = makeTableRow(isHeader ? .header : .body, from: first)
        var cellStart = first
        for pipe in pipePositions(from: first) {
            lexInline(cellStart, pipe)
            add(.syntaxMarker, pipe, pipe + 1)
            cellStart = pipe + 1
        }
        lexInline(cellStart, c.count)
    }

    private func makeTableRow(_ kind: MarkdownTable.Row.Kind, from first: Int) -> MarkdownTable.Row {
        let end = trimmedEnd()
        let pipes = pipePositions(from: first)
        let hasLeadingPipe = pipes.first == first
        let hasTrailingPipe = pipes.last == end - 1 && (pipes.count > 1 || !hasLeadingPipe)
        var separators = pipes[...]
        if hasLeadingPipe { separators = separators.dropFirst() }
        if hasTrailingPipe { separators = separators.dropLast() }
        var cells: [NSRange] = []
        var cellStart = hasLeadingPipe ? first + 1 : first
        for pipe in separators {
            cells.append(NSRange(location: offset + cellStart, length: pipe - cellStart))
            cellStart = pipe + 1
        }
        let lastEnd = hasTrailingPipe ? end - 1 : end
        cells.append(NSRange(location: offset + cellStart, length: max(0, lastEnd - cellStart)))
        return MarkdownTable.Row(
            kind: kind,
            range: NSRange(location: offset + first, length: end - first),
            cells: cells,
            pipes: pipes.map { offset + $0 }
        )
    }

    private func alignment(of cell: NSRange) -> MarkdownTable.Alignment {
        let units = Self.trimmed(c[(cell.location - offset)..<(cell.upperBound - offset)])
        switch (units.first == Char.colon, units.count > 1 && units.last == Char.colon) {
        case (true, true): return .center
        case (false, true): return .right
        default: return .left
        }
    }

    /// Column count of a GFM table delimiter row such as `| --- | :-: |`, or nil.
    static func delimiterRowColumns(_ line: [UInt16]) -> Int? {
        guard line.contains(Char.pipe) else { return nil }
        var cells = line.split(separator: Char.pipe, omittingEmptySubsequences: false).map(Self.trimmed)
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        guard !cells.isEmpty else { return nil }
        for var cell in cells {
            if cell.first == Char.colon { cell = cell.dropFirst() }
            if cell.last == Char.colon { cell = cell.dropLast() }
            guard !cell.isEmpty, cell.allSatisfy({ $0 == Char.dash }) else { return nil }
        }
        return cells.count
    }

    private static func trimmed(_ slice: ArraySlice<UInt16>) -> ArraySlice<UInt16> {
        var result = slice
        while let first = result.first, Char.isWhitespace(first) { result = result.dropFirst() }
        while let last = result.last, Char.isWhitespace(last) { result = result.dropLast() }
        return result
    }

    /// Heading level when `line` is a setext underline (`===` or `---`), else nil.
    static func setextLevel(_ line: [UInt16]) -> Int? {
        var i = 0
        while i < line.count && line[i] == Char.space { i += 1 }
        guard i < 4, i < line.count else { return nil }
        let marker = line[i]
        guard marker == Char.equals || marker == Char.dash else { return nil }
        var end = line.count
        while end > i && Char.isWhitespace(line[end - 1]) { end -= 1 }
        guard line[i..<end].allSatisfy({ $0 == marker }) else { return nil }
        if marker == Char.dash && end - i < 2 { return nil }
        return marker == Char.equals ? 1 : 2
    }

    // MARK: Inline spans

    private struct Delimiter {
        var marker: UInt16
        var start: Int
        var length: Int
        var canOpen: Bool
        var canClose: Bool
        /// Characters still available, taken from the inner (right) end when opening.
        var openRemaining: Int
        /// Characters already used, taken from the inner (left) end when closing.
        var closeUsed = 0
    }

    /// Inline spans of `start..<end`; inside a link's text no nested links are recognised.
    private mutating func lexInline(_ start: Int, _ end: Int, isLinkText: Bool = false) {
        let allowsLinks = !isLinkText
        var delimiters: [Delimiter] = []
        var i = start
        while i < end {
            let unit = c[i]
            switch unit {
            case Char.backslash where i + 1 < end && Char.isASCIIPunctuation(c[i + 1]):
                add(.syntaxMarker, i, i + 1)
                i += 2
            case Char.backtick:
                i = lexCodeSpan(at: i, end: end)
            case Char.lbracket where allowsLinks && i + 1 < end && c[i + 1] == Char.lbracket:
                if let after = lexWikiLink(at: i, end: end) { i = after } else { i += 2 }
            case Char.lbracket where allowsLinks:
                i = lexLink(at: i, textStart: i + 1, end: end, isImage: false) ?? i + 1
            case Char.bang where allowsLinks && i + 1 < end && c[i + 1] == Char.lbracket:
                i = lexLink(at: i, textStart: i + 2, end: end, isImage: true) ?? i + 2
            case Char.lt where allowsLinks:
                i = lexAutolink(at: i, end: end) ?? i + 1
            case _ where allowsLinks && (unit == Char.lowerH || unit == Char.lowerW):
                i = lexBareURL(at: i, start: start, end: end) ?? i + 1
            case Char.hash:
                i = lexTag(at: i, start: start, end: end) ?? i + 1
            case Char.star, Char.underscore, Char.tilde:
                var j = i
                while j < end && c[j] == unit { j += 1 }
                if let delimiter = makeDelimiter(unit, i, j, start: start, end: end) {
                    delimiters.append(delimiter)
                }
                i = j
            default:
                i += 1
            }
        }
        resolveEmphasis(delimiters)
    }

    private mutating func lexCodeSpan(at i: Int, end: Int) -> Int {
        var j = i
        while j < end && c[j] == Char.backtick { j += 1 }
        let length = j - i
        var k = j
        while k < end {
            guard c[k] == Char.backtick else { k += 1; continue }
            var m = k
            while m < end && c[m] == Char.backtick { m += 1 }
            if m - k == length {
                add(.syntaxMarker, i, j)
                add(.inlineCode, j, k)
                add(.syntaxMarker, k, m)
                return m
            }
            k = m
        }
        return j
    }

    private mutating func lexWikiLink(at i: Int, end: Int) -> Int? {
        var k = i + 2
        while k + 1 < end {
            if c[k] == Char.rbracket && c[k + 1] == Char.rbracket { break }
            if c[k] == Char.lbracket || c[k] == Char.rbracket { return nil }
            k += 1
        }
        guard k + 1 < end, c[(i + 2)..<k].contains(where: { !Char.isWhitespace($0) }) else { return nil }
        add(.wikiLink, i, k + 2)
        add(.syntaxMarker, i, i + 2)
        add(.syntaxMarker, k, k + 2)
        return k + 2
    }

    private mutating func lexLink(at i: Int, textStart: Int, end: Int, isImage: Bool) -> Int? {
        var depth = 1
        var k = textStart
        while k < end {
            if c[k] == Char.backslash { k += 2; continue }
            if c[k] == Char.lbracket { depth += 1 }
            if c[k] == Char.rbracket {
                depth -= 1
                if depth == 0 { break }
            }
            k += 1
        }
        guard k + 1 < end, c[k + 1] == Char.lparen else { return nil }
        var parens = 1
        var m = k + 2
        while m < end {
            if c[m] == Char.backslash { m += 2; continue }
            if c[m] == Char.lparen { parens += 1 }
            if c[m] == Char.rparen {
                parens -= 1
                if parens == 0 { break }
            }
            m += 1
        }
        guard m < end else { return nil }
        add(.syntaxMarker, i, textStart)
        add(.link, textStart, k)
        lexInline(textStart, k, isLinkText: true)
        add(.syntaxMarker, k, k + 2)
        add(.linkDestination, k + 2, m)
        add(.syntaxMarker, m, m + 1)
        if isImage {
            let source = linkDestinationSource(from: k + 2, to: m)
            add(.image(source: source), i, m + 1)
        }
        return m + 1
    }

    private func linkDestinationSource(from start: Int, to end: Int) -> String {
        var sourceStart = start
        while sourceStart < end && Char.isWhitespace(c[sourceStart]) { sourceStart += 1 }
        guard sourceStart < end else { return "" }
        if c[sourceStart] == Char.lt {
            var sourceEnd = sourceStart + 1
            while sourceEnd < end && c[sourceEnd] != Char.gt { sourceEnd += 1 }
            return String(decoding: c[(sourceStart + 1)..<sourceEnd], as: UTF16.self)
        }
        var sourceEnd = sourceStart
        while sourceEnd < end {
            if c[sourceEnd] == Char.backslash {
                sourceEnd = min(sourceEnd + 2, end)
            } else if Char.isWhitespace(c[sourceEnd]) {
                break
            } else {
                sourceEnd += 1
            }
        }
        return String(decoding: c[sourceStart..<sourceEnd], as: UTF16.self)
    }

    /// `<https://example.com>` or `<name@example.com>`.
    private mutating func lexAutolink(at i: Int, end: Int) -> Int? {
        var k = i + 1
        while k < end && c[k] != Char.gt {
            if Char.isWhitespace(c[k]) || c[k] == Char.lt { return nil }
            k += 1
        }
        guard k < end, k > i + 1 else { return nil }
        let content = c[(i + 1)..<k]
        let hasScheme: Bool = {
            guard let colon = content.firstIndex(of: Char.colon), colon - (i + 1) >= 2 else { return false }
            return Char.isASCIILetter(content[content.startIndex])
        }()
        guard hasScheme || content.contains(Char.at) else { return nil }
        add(.syntaxMarker, i, i + 1)
        add(.link, i + 1, k)
        add(.syntaxMarker, k, k + 1)
        return k + 1
    }

    private static let urlPrefixes: [[UInt16]] = ["https://", "http://", "www."].map { Array($0.utf16) }

    /// GFM extended autolinks: `https://…`, `http://…`, `www.…`.
    private mutating func lexBareURL(at i: Int, start: Int, end: Int) -> Int? {
        if i > start && Char.isAlphanumeric(c[i - 1]) { return nil }
        guard let prefix = Self.urlPrefixes.first(where: { p in
            i + p.count < end && Array(c[i..<(i + p.count)]) == p
        }) else { return nil }
        var j = i
        while j < end && !Char.isWhitespace(c[j]) && c[j] != Char.lt { j += 1 }
        while j > i + prefix.count {
            let last = c[j - 1]
            if Char.trailingURLPunctuation.contains(last) {
                j -= 1
            } else if last == Char.rparen,
                      c[i..<j].filter({ $0 == Char.lparen }).count < c[i..<j].filter({ $0 == Char.rparen }).count {
                j -= 1
            } else {
                break
            }
        }
        guard j > i + prefix.count else { return nil }
        add(.link, i, j)
        return j
    }

    /// A Tag is `#` followed by letters (diacritics included), digits, `-` and
    /// `_`, with at least one letter. It must not continue a word, so `C#`,
    /// `page#section` and `&#123;` are not Tags; `# Heading` is not one either
    /// because of the space.
    private mutating func lexTag(at i: Int, start: Int, end: Int) -> Int? {
        if i > start && !Char.tagMayFollow(c, at: i - 1) { return nil }
        var j = i + 1
        var hasLetter = false
        while j < end {
            guard let (scalar, width) = Char.scalar(in: c, at: j, end: end) else { break }
            if scalar == "-" || scalar == "_" {
                j += width
                continue
            }
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
                hasLetter = true
            case .decimalNumber, .nonspacingMark, .spacingMark, .enclosingMark:
                break
            default:
                return finishTag(i, j, hasLetter)
            }
            j += width
        }
        return finishTag(i, j, hasLetter)
    }

    private mutating func finishTag(_ i: Int, _ j: Int, _ hasLetter: Bool) -> Int? {
        guard hasLetter || (recognizesTagPrefixes && j > i + 1) else { return nil }
        add(.tag, i, j)
        return j
    }

    private func makeDelimiter(_ marker: UInt16, _ i: Int, _ j: Int, start: Int, end: Int) -> Delimiter? {
        let length = j - i
        if marker == Char.tilde && length > 2 { return nil }
        let before: UInt16? = i > start ? c[i - 1] : nil
        let after: UInt16? = j < end ? c[j] : nil
        let beforeIsSpace = before.map(Char.isWhitespace) ?? true
        let afterIsSpace = after.map(Char.isWhitespace) ?? true
        let beforeIsPunct = before.map(Char.isPunctuation) ?? false
        let afterIsPunct = after.map(Char.isPunctuation) ?? false
        let leftFlanking = !afterIsSpace && (!afterIsPunct || beforeIsSpace || beforeIsPunct)
        let rightFlanking = !beforeIsSpace && (!beforeIsPunct || afterIsSpace || afterIsPunct)
        var canOpen = leftFlanking
        var canClose = rightFlanking
        if marker == Char.underscore {
            canOpen = leftFlanking && (!rightFlanking || beforeIsPunct)
            canClose = rightFlanking && (!leftFlanking || afterIsPunct)
        }
        guard canOpen || canClose else { return nil }
        return Delimiter(marker: marker, start: i, length: length, canOpen: canOpen, canClose: canClose, openRemaining: length)
    }

    private mutating func resolveEmphasis(_ delimiters: [Delimiter]) {
        var stack: [Delimiter] = []
        for var closer in delimiters {
            if closer.canClose {
                while closer.closeUsed < closer.length,
                      let index = stack.lastIndex(where: { opener in
                          opener.marker == closer.marker
                              && (closer.marker != Char.tilde || opener.length == closer.length)
                              && !Self.violatesRuleOfThree(opener, closer)
                      }) {
                    var opener = stack[index]
                    let available = closer.length - closer.closeUsed
                    let use: Int
                    if closer.marker == Char.tilde {
                        use = opener.length
                    } else {
                        use = opener.openRemaining >= 2 && available >= 2 ? 2 : 1
                    }
                    let openInner = opener.start + opener.openRemaining
                    let closeInner = closer.start + closer.closeUsed
                    let kind: MarkdownToken.Kind = closer.marker == Char.tilde ? .strikethrough : (use == 2 ? .strong : .emphasis)
                    add(kind, openInner, closeInner)
                    add(.syntaxMarker, openInner - use, openInner)
                    add(.syntaxMarker, closeInner, closeInner + use)
                    opener.openRemaining -= use
                    closer.closeUsed += use
                    stack.removeSubrange((index + 1)...)
                    if opener.openRemaining == 0 {
                        stack.remove(at: index)
                    } else {
                        stack[index] = opener
                    }
                }
            }
            if closer.canOpen && closer.closeUsed == 0 {
                stack.append(closer)
            }
        }
    }

    /// CommonMark's "multiple of 3" rule for `*`/`_` runs that can both open and close.
    private static func violatesRuleOfThree(_ opener: Delimiter, _ closer: Delimiter) -> Bool {
        guard opener.canClose || closer.canOpen else { return false }
        let sum = opener.length + closer.length
        return sum % 3 == 0 && !(opener.length % 3 == 0 && closer.length % 3 == 0)
    }
}

/// UTF-16 code units and character classes used by the lexer.
enum Char {
    static let tab: UInt16 = 0x09
    static let lf: UInt16 = 0x0A
    static let cr: UInt16 = 0x0D
    static let space: UInt16 = 0x20
    static let bang: UInt16 = 0x21
    static let hash: UInt16 = 0x23
    static let lparen: UInt16 = 0x28
    static let rparen: UInt16 = 0x29
    static let star: UInt16 = 0x2A
    static let plus: UInt16 = 0x2B
    static let dash: UInt16 = 0x2D
    static let dot: UInt16 = 0x2E
    static let colon: UInt16 = 0x3A
    static let lt: UInt16 = 0x3C
    static let equals: UInt16 = 0x3D
    static let gt: UInt16 = 0x3E
    static let at: UInt16 = 0x40
    static let upperX: UInt16 = 0x58
    static let lbracket: UInt16 = 0x5B
    static let backslash: UInt16 = 0x5C
    static let rbracket: UInt16 = 0x5D
    static let underscore: UInt16 = 0x5F
    static let backtick: UInt16 = 0x60
    static let lowerH: UInt16 = 0x68
    static let lowerW: UInt16 = 0x77
    static let x: UInt16 = 0x78
    static let pipe: UInt16 = 0x7C
    static let tilde: UInt16 = 0x7E

    static let trailingURLPunctuation: Set<UInt16> = Set("?!.,:*_~'\"".utf16)
    /// ASCII characters after which a `#` may start a Tag (besides whitespace and line start).
    private static let tagPrefixes: Set<UInt16> = Set("([{\"',;:*_~>|".utf16)

    static func isWhitespace(_ u: UInt16) -> Bool { u == space || u == tab }
    static func isDigit(_ u: UInt16) -> Bool { u >= 0x30 && u <= 0x39 }
    static func isASCIILetter(_ u: UInt16) -> Bool { (u | 0x20) >= 0x61 && (u | 0x20) <= 0x7A }

    static func isASCIIPunctuation(_ u: UInt16) -> Bool {
        (u >= 0x21 && u <= 0x2F) || (u >= 0x3A && u <= 0x40) || (u >= 0x5B && u <= 0x60) || (u >= 0x7B && u <= 0x7E)
    }

    static func isPunctuation(_ u: UInt16) -> Bool {
        if u < 0x80 { return isASCIIPunctuation(u) }
        guard let scalar = Unicode.Scalar(u) else { return false }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    /// Letters and digits, including non-ASCII ones (a surrogate counts as a letter).
    static func isAlphanumeric(_ u: UInt16) -> Bool {
        if u < 0x80 { return isDigit(u) || isASCIILetter(u) }
        guard let scalar = Unicode.Scalar(u) else { return true }
        return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    /// Whether a Tag may start right after the code unit at `i`: whitespace,
    /// some ASCII punctuation, or any non-ASCII character that is not part of
    /// a word (so `„#tag“`, `—#tag` and a no-break space before `#tag` work).
    static func tagMayFollow(_ c: [UInt16], at i: Int) -> Bool {
        let u = c[i]
        if u < 0x80 { return isWhitespace(u) || tagPrefixes.contains(u) }
        if isAlphanumeric(u) { return false }
        guard let scalar = Unicode.Scalar(u) else { return false }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return false
        default:
            return true
        }
    }

    /// Decodes the Unicode scalar starting at `i`, handling surrogate pairs.
    static func scalar(in c: [UInt16], at i: Int, end: Int) -> (Unicode.Scalar, Int)? {
        let u = c[i]
        if UTF16.isLeadSurrogate(u) {
            guard i + 1 < end, UTF16.isTrailSurrogate(c[i + 1]) else { return nil }
            let value = 0x10000 + ((UInt32(u) - 0xD800) << 10) + (UInt32(c[i + 1]) - 0xDC00)
            return Unicode.Scalar(value).map { ($0, 2) }
        }
        return Unicode.Scalar(u).map { ($0, 1) }
    }
}
