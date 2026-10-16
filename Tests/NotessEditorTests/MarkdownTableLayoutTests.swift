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
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var indices = [CFIndex](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetStringIndices(run, CFRange(), &indices)
            CTRunGetPositions(run, CFRange(), &positions)
            if let glyph = indices.firstIndex(of: index - lineRange.location) {
                return positions[glyph].x
            }
        }
        return .nan
    }

    /// Left edges of the `|` characters of every line, line by line.
    private func pipeColumns() -> [[CGFloat]] {
        let string = textView.string as NSString
        var result: [[CGFloat]] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byLines) { line, range, _, _ in
            guard let line, line.contains("|") else { return }
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
        #expect(columns.count == 4)
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
        #expect(after[2][1] - before[2][1] > 30)
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
    }
}

private extension NSString {
    var utf16Units: [UInt16] {
        (0..<length).map { character(at: $0) }
    }
}
