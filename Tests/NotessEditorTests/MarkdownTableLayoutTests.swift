import AppKit
import Testing
@testable import NotessEditor

@MainActor
@Suite("Markdown tables in the editor")
struct MarkdownTableLayoutTests {
    private let window: NSWindow
    private let textView: MarkdownTextView

    init() {
        let scrollView = MarkdownTextViewFactory.makeScrollView(style: .standard)
        textView = scrollView.documentView as! MarkdownTextView
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        scrollView.frame = window.contentLayoutRect
    }

    /// Where the glyph of the character at `index` is drawn in its line.
    ///
    /// Caret offsets cannot be used: CoreText puts the caret after a kerned
    /// character in the middle of the extra space.
    private func x(at index: Int) -> CGFloat {
        Self.x(at: index, in: textView)
    }

    static func x(at index: Int, in textView: NSTextView) -> CGFloat {
        guard let storage = textView.textStorage else { return .nan }
        let lineRange = (storage.string as NSString).lineRange(for: NSRange(location: index, length: 0))
        let line = CTLineCreateWithAttributedString(storage.attributedSubstring(from: lineRange))
        // CoreText knows nothing of the paragraph's indent, which shifts the first line.
        let indent = (storage.attribute(.paragraphStyle, at: lineRange.location, effectiveRange: nil) as? NSParagraphStyle)?.firstLineHeadIndent ?? 0
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var indices = [CFIndex](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetStringIndices(run, CFRange(), &indices)
            CTRunGetPositions(run, CFRange(), &positions)
            if let glyph = indices.firstIndex(of: index - lineRange.location) {
                return positions[glyph].x + indent
            }
        }
        return .nan
    }

    /// Left edges of the `|` characters of every line but the hidden delimiter row, line by line.
    private func pipeColumns() -> [[CGFloat]] {
        let string = textView.string as NSString
        var result: [[CGFloat]] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byLines) { line, range, _, _ in
            guard let line, line.contains("|"), !line.allSatisfy({ "|-: ".contains($0) }) else { return }
            var xs: [CGFloat] = []
            for (offset, unit) in (line as NSString).utf16Units.enumerated() where unit == UInt16(UInt8(ascii: "|")) {
                xs.append(x(at: range.location + offset))
            }
            result.append(xs)
        }
        return result
    }

    private func expectAligned(_ columns: [[CGFloat]], sourceLocation: SourceLocation = #_sourceLocation) {
        let count = columns.map(\.count).max() ?? 0
        for column in 0..<count {
            let xs = columns.compactMap { $0.indices.contains(column) ? $0[column] : nil }
            let spread = (xs.max() ?? 0) - (xs.min() ?? 0)
            #expect(spread < 1, "pipe \(column) at \(xs)", sourceLocation: sourceLocation)
        }
    }

    @Test("the pipes of every row line up in columns, the text is unchanged")
    func columnsLineUp() {
        let text = "| Jméno | Role |\n| --- | --- |\n| Jan Novák | PM |\n| A | Vedoucí **projektu** `x` |"
        textView.string = text
        let columns = pipeColumns()
        #expect(columns.count == 3)
        expectAligned(columns)
        #expect(columns[0][1] - columns[0][0] > 40)
        #expect(textView.string == text)
    }

    @Test("typing in a cell lines up every row again")
    func typingRealigns() {
        textView.string = "| a | b |\n| - | - |\n| c | d |"
        let before = pipeColumns()
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.insertText("dlouhý text ", replacementRange: textView.selectedRange())
        let after = pipeColumns()
        expectAligned(after)
        #expect(after[1][1] - before[1][1] > 30)
    }

    @Test("typing in a cell keeps the caret after the typed character")
    func caretStays() {
        textView.string = "| ab | cd |\n| -- | -- |\n| ef | gh |\n\nkonec"
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        textView.insertText("x", replacementRange: textView.selectedRange())
        #expect(textView.selectedRange() == NSRange(location: 5, length: 0))
        textView.insertText("y", replacementRange: textView.selectedRange())
        #expect(textView.selectedRange() == NSRange(location: 6, length: 0))
        #expect(textView.string.hasPrefix("| abxy | cd |"))
    }

    @Test("right- and centre-aligned columns follow the delimiter row")
    func alignment() {
        let text = "| a | b |\n| --: | :-: |\n| dlouhé | dlouhé |"
        textView.string = text
        let string = text as NSString
        expectAligned(pipeColumns())
        // Right: the last characters of both cells end at the same place.
        let short = x(at: string.range(of: "a").location)
        let long = x(at: string.range(of: "é").location)
        #expect(abs(short - long) < 2)
        // Centre: the short cell's text starts well inside the column.
        let b = x(at: string.range(of: "b").location)
        let pipe = x(at: string.range(of: "| b").location)
        let next = x(at: string.range(of: "|", options: .backwards, range: NSRange(location: 0, length: 9)).location)
        #expect(b - pipe > 10)
        #expect(next - b > 10)
    }

    static func layoutFragments(of textView: NSTextView) -> [NSTextLayoutFragment] {
        guard let layoutManager = textView.textLayoutManager else { return [] }
        var fragments: [NSTextLayoutFragment] = []
        layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location, options: [.ensuresLayout]) {
            fragments.append($0)
            return true
        }
        return fragments
    }

    private func attribute(_ key: NSAttributedString.Key, at index: Int) -> Any? {
        textView.textStorage?.attribute(key, at: index, effectiveRange: nil)
    }

    @Test("a table is drawn as a grid: pipes and the delimiter row are hidden, the text is not")
    func grid() throws {
        let text = "Před\n| Jméno | Role |\n| --- | --: |\n| Jan | PM |\nPo"
        textView.string = text
        let string = text as NSString

        #expect(attribute(.foregroundColor, at: string.range(of: "| Jméno").location) as? NSColor == .clear)
        #expect(attribute(.foregroundColor, at: string.range(of: "--:").location) as? NSColor == .clear)
        #expect(attribute(.foregroundColor, at: string.range(of: "Jan").location) as? NSColor != .clear)
        #expect(textView.string == text)

        let fragments = Self.layoutFragments(of: textView)
        #expect(fragments.map { $0 is TableRowLayoutFragment } == [false, true, true, true, false])
        let rows = fragments.compactMap { ($0 as? TableRowLayoutFragment)?.decoration }
        #expect(rows.map(\.kind) == [.header, .delimiter, .body])
        #expect(Set(rows.map(\.columnLines)).count == 1)
        // The delimiter row is squeezed to a hairline.
        #expect(fragments[2].layoutFragmentFrame.height < fragments[3].layoutFragmentFrame.height / 4)

        // Every inner grid line runs through its hidden pipe.
        let lines = try #require(rows.first?.columnLines)
        #expect(lines.count == 3)
        let pipe = string.range(of: "| PM").location
        #expect(lines[1] > x(at: pipe) && lines[1] < x(at: pipe + 1))
    }

    private func delimiterRowIsHidden(_ text: String = "| - |") -> Bool {
        let location = (textView.string as NSString).range(of: text).location
        return attribute(.foregroundColor, at: location) as? NSColor == .clear
            && attribute(.notessTableRow, at: location) != nil
    }

    @Test("the delimiter row shows its markup while the caret is on it")
    func delimiterRowShownAtCaret() {
        textView.string = "| a | b |\n| - | - |\n| c | d |"
        let string = textView.string as NSString
        #expect(delimiterRowIsHidden("| - | - |"))

        textView.setSelectedRange(NSRange(location: string.range(of: "| - | - |").upperBound, length: 0))
        #expect(!delimiterRowIsHidden("| - | - |"))
        #expect(Self.layoutFragments(of: textView).map { $0 is TableRowLayoutFragment } == [true, false, true])

        textView.setSelectedRange(NSRange(location: string.range(of: "| c").location, length: 0))
        #expect(delimiterRowIsHidden("| - | - |"))
        #expect(Self.layoutFragments(of: textView).allSatisfy { $0 is TableRowLayoutFragment })
        #expect(textView.string == string as String)
    }

    @Test("a delimiter row being typed stays visible until the caret leaves it")
    func typingDelimiterRow() {
        textView.string = ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        for character in "| a | b |\n| - | - |" {
            textView.insertText(String(character), replacementRange: textView.selectedRange())
            #expect(attribute(.foregroundColor, at: textView.selectedRange().location - 1) as? NSColor != .clear)
        }
        #expect(attribute(.notessTableRow, at: 0) != nil)
        textView.insertText("\n| c | d |", replacementRange: textView.selectedRange())
        #expect(delimiterRowIsHidden("| - | - |"))
    }

    @Test("a table too wide for the view keeps its rules but drops the column lines")
    func wrappedTable() {
        func columnLines(width: CGFloat) -> [Bool] {
            let readOnly = MarkdownTextViewFactory.makeReadOnlyTextView()
            readOnly.frame = NSRect(x: 0, y: 0, width: width, height: 200)
            window.contentView?.addSubview(readOnly)
            readOnly.string = "| a | b |\n| - | - |\n| c | \(String(repeating: "dlouhý ", count: 6)) |"
            return Self.layoutFragments(of: readOnly).compactMap { ($0 as? TableRowLayoutFragment)?.drawsColumnLines }
        }
        #expect(columnLines(width: 600) == [true, false, true])
        #expect(columnLines(width: 150) == [false, false, false])
    }

    @Test("breaking a table shows its pipes again and drops the grid")
    func brokenTable() {
        textView.string = "| a | b |\n| - | - |\n| c | d |"
        let delimiter = (textView.string as NSString).range(of: "| - | - |\n")
        textView.setSelectedRange(delimiter)
        textView.insertText("", replacementRange: delimiter)

        #expect(textView.string == "| a | b |\n| c | d |")
        #expect(attribute(.foregroundColor, at: 0) as? NSColor != .clear)
        #expect(attribute(.notessTableRow, at: 0) == nil)
        #expect(!Self.layoutFragments(of: textView).contains { $0 is TableRowLayoutFragment })
    }

    /// Glyph x of the last character of `cell` (the `occurrence`-th match), right edge approximated by its start.
    private func x(of text: String, in view: NSTextView? = nil) -> CGFloat {
        let view = view ?? textView
        return Self.x(at: (view.string as NSString).range(of: text).location, in: view)
    }

    @Test("the first column follows its alignment without an opening pipe")
    func firstColumnWithoutOpeningPipe() {
        let tables = [
            "a | b\n---: | ---\nlonger | c",
            "a | b |\n---: | --- |\nlonger | c |",
            "| a | b |\n| ---: | --- |\n| longer | c |",
            "| a | b\n| ---: | ---\n| longer | c",
            "a | b\n---: | ---\n| longer | c",
        ]
        for text in tables {
            textView.string = text
            #expect(textView.string == text)
            // Right: the single character "a" ends where "longer" ends.
            let aRight = x(of: "a ") + Self.width("a")
            let longerRight = x(of: "longer") + Self.width("longer")
            #expect(abs(aRight - longerRight) < 2, "right edges for \(text)")
        }
    }

    @Test("a centred first column without an opening pipe is centred, indented and with unicode")
    func firstColumnCentred() {
        let text = "  a | b\n  :---: | ---\n  dlouhé žluťoučký | c"
        textView.string = text
        #expect(textView.string == text)
        let short = x(of: "a ") + Self.width("a") / 2
        let long = x(of: "dlouhé") + Self.width("dlouhé žluťoučký") / 2
        #expect(abs(short - long) < 2)
    }

    @Test("a left-aligned first column without an opening pipe is not moved")
    func firstColumnLeft() {
        textView.string = "a | b\n--- | ---\nlonger | c"
        #expect(abs(x(of: "a ") - x(of: "longer")) < 0.5)
    }

    @Test("formatting a table without opening pipes leaves no undo entry or edit")
    func noUndoForAlignment() {
        textView.string = "a | b\n---: | ---\nlonger | c"
        #expect(textView.undoManager?.canUndo != true)
    }

    private static func width(_ text: String) -> CGFloat {
        let font = MarkdownEditorStyle.standard.font
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    @Test("a table in the read-only view lines up too")
    func readOnly() {
        let readOnly = MarkdownTextViewFactory.makeReadOnlyTextView()
        readOnly.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        window.contentView?.addSubview(readOnly)
        readOnly.string = "| Jméno | Role |\n| --- | --- |\n| Jan Novák | PM |"
        let string = readOnly.string as NSString
        func x(_ index: Int) -> CGFloat { Self.x(at: index, in: readOnly) }
        let headerPipe = x(string.range(of: "| Role").location)
        let bodyPipe = x(string.range(of: "| PM").location)
        #expect(abs(headerPipe - bodyPipe) < 1)
        #expect(Self.layoutFragments(of: readOnly).contains { $0 is TableRowLayoutFragment })
    }

    @Test("the read-only view aligns a first column without an opening pipe")
    func readOnlyFirstColumn() {
        let readOnly = MarkdownTextViewFactory.makeReadOnlyTextView()
        readOnly.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        window.contentView?.addSubview(readOnly)
        readOnly.string = "a | b\n---: | ---\nlonger | c"
        let aRight = x(of: "a ", in: readOnly) + Self.width("a")
        let longerRight = x(of: "longer", in: readOnly) + Self.width("longer")
        #expect(abs(aRight - longerRight) < 2)
    }
}

private extension NSString {
    var utf16Units: [UInt16] {
        (0..<length).map { character(at: $0) }
    }
}
