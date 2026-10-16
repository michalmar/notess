import AppKit
import NotessCore

/// What `TableRowLayoutFragment` draws around one row of a table.
final class TableRowDecoration: NSObject, @unchecked Sendable {
    let kind: MarkdownTable.Row.Kind
    let isLast: Bool
    /// The x of every vertical grid line from the line start, outer borders included.
    let columnLines: [CGFloat]
    let border: NSColor
    let headerBackground: NSColor

    init(kind: MarkdownTable.Row.Kind, isLast: Bool, columnLines: [CGFloat], border: NSColor, headerBackground: NSColor) {
        self.kind = kind
        self.isLast = isLast
        self.columnLines = columnLines
        self.border = border
        self.headerBackground = headerBackground
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TableRowDecoration else { return false }
        return kind == other.kind && isLast == other.isLast && columnLines == other.columnLines
            && border == other.border && headerBackground == other.headerBackground
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(kind)
        hasher.combine(isLast)
        hasher.combine(columnLines)
        return hasher.finalize()
    }
}

/// The layout fragment of one table row: its text plus the table grid, a
/// shaded header and a rule below the header and every row.
///
/// Rows of one table share their `columnLines`, so the vertical lines join up.
final class TableRowLayoutFragment: NSTextLayoutFragment, @unchecked Sendable {
    let decoration: TableRowDecoration

    init(textElement: NSTextElement, range: NSTextRange?, decoration: TableRowDecoration) {
        self.decoration = decoration
        super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    /// The grid's left and right edge in the fragment, nil before layout.
    private var gridSpan: ClosedRange<CGFloat>? {
        guard let line = textLineFragments.first,
              let first = decoration.columnLines.first,
              let last = decoration.columnLines.last else { return nil }
        let origin = line.typographicBounds.minX + line.locationForCharacter(at: line.characterRange.location).x
        return (origin + first).rounded(.down)...(origin + last).rounded(.down)
    }

    /// The bottom of the row's text plus its padding. Not the fragment's
    /// height: at the end of the text that lacks the padding, or includes the
    /// empty last line.
    private var rowHeight: CGFloat {
        let lines = textLineFragments.filter { $0.characterRange.length > 0 }
        guard let last = lines.last else { return layoutFragmentFrame.height }
        let padding = decoration.kind == .delimiter ? 0 : TableLayout.cellPadding / 2
        return last.typographicBounds.maxY + padding
    }

    override var renderingSurfaceBounds: CGRect {
        let bounds = super.renderingSurfaceBounds
        guard let span = gridSpan else { return bounds }
        let height = rowHeight
        return bounds.union(CGRect(x: span.lowerBound - 1, y: 0, width: span.upperBound - span.lowerBound + 2, height: height))
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        guard let span = gridSpan else {
            super.draw(at: point, in: context)
            return
        }
        let height = rowHeight
        let left = point.x + span.lowerBound
        let width = span.upperBound - span.lowerBound + 1

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        if decoration.kind == .header {
            decoration.headerBackground.setFill()
            CGRect(x: left, y: point.y, width: width, height: height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        super.draw(at: point, in: context)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        decoration.border.setFill()
        let origin = point.x + span.lowerBound - decoration.columnLines[0].rounded(.down)
        for x in decoration.columnLines {
            CGRect(x: origin + x.rounded(.down), y: point.y, width: 1, height: height).fill()
        }
        if decoration.kind == .header {
            CGRect(x: left, y: point.y, width: width, height: 1).fill()
        }
        if decoration.kind != .delimiter {
            CGRect(x: left, y: point.y + height - 1, width: width, height: 1).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
