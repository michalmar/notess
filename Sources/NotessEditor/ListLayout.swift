import AppKit
import NotessCore

extension NSAttributedString.Key {
    /// A `ListBulletDecoration` on every line of an unordered list item.
    static let notessListBullet = NSAttributedString.Key("NotessListBullet")
}

/// Lays out the lines of Markdown lists without changing their text (ADR 0002).
///
/// Every item gets a hanging indent: its text, wrapped lines and continuation
/// lines start at the same x, one `step` further right per level, and the
/// marker ends a `gap` before it. A step fits a three-digit number, so the
/// text of numbered siblings stays aligned from 1 to 999; a longer number
/// pushes its own line right rather than overlapping the text. The level,
/// not the source indentation, sets the indent, so the whitespace before the
/// marker and the text is squeezed to (almost) nothing: spaces by a negative
/// kern, tabs by tab stops a hair apart. Only the character right before the
/// marker or the text keeps its width, and the distance up to the text goes
/// before that last character. An unordered item's marker is hidden;
/// `ListItemLayoutFragment` draws a solid bullet over it. Ordered markers
/// keep their source number.
@MainActor
struct ListLayout {
    private let font: NSFont
    private let markerColor: NSColor
    private let gap: CGFloat
    private let step: CGFloat
    private let spaceWidth: CGFloat
    private let bulletDiameter: CGFloat
    private var markerWidths: [String: CGFloat] = [:]

    /// The distance between tab stops that stand for squeezed tabs.
    nonisolated static let squeezedTab: CGFloat = 0.01
    /// The tab interval after the squeezed tabs, the system default.
    nonisolated static let defaultTabInterval: CGFloat = 28

    init(style: MarkdownEditorStyle) {
        font = style.font
        markerColor = style.colors.text
        gap = (style.font.pointSize * 0.4).rounded()
        spaceWidth = Self.width(of: " ", font: style.font)
        bulletDiameter = style.font.pointSize * 0.36
        step = max(Self.width(of: "000.", font: style.font), Self.width(of: "000)", font: style.font)) + gap
    }

    /// Where the text of an item at `level` starts.
    func contentX(level: Int) -> CGFloat {
        CGFloat(level + 1) * step
    }

    mutating func layOut(_ line: MarkdownListLine, in storage: NSTextStorage) {
        let string = storage.mutableString
        var contentX = contentX(level: line.level)
        let firstLineX: CGFloat
        var tabStops: [CGFloat] = []

        if let marker = line.marker {
            let markerText = string.substring(with: line.markerRange)
            let markerWidth = width(of: markerText)
            var markerX = switch marker {
            case .bullet: contentX - gap - bulletDiameter / 2 - markerWidth / 2
            case .number: contentX - gap - markerWidth
            }
            // Room for the indentation's last character, which keeps its width.
            let minimum = line.indentation.length > 0 ? spaceWidth + CGFloat(line.indentation.length) * Self.squeezedTab : 0
            if markerX < minimum {
                contentX += minimum - markerX
                markerX = minimum
            }
            firstLineX = squeeze(line.indentation, before: markerX, in: storage, tabStops: &tabStops)
            let separator = NSRange(location: line.markerRange.upperBound, length: line.contentStart - line.markerRange.upperBound)
            stretch(separator, from: markerX + markerWidth, to: contentX, in: storage, tabStops: &tabStops)

            switch marker {
            case .bullet:
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: line.markerRange)
                let decoration = ListBulletDecoration(
                    markerOffset: line.markerRange.location - line.range.location,
                    markerWidth: markerWidth,
                    diameter: bulletDiameter,
                    raise: font.xHeight / 2,
                    color: markerColor
                )
                storage.addAttribute(.notessListBullet, value: decoration, range: paragraphRange(of: line, in: string))
            case .number:
                storage.addAttribute(.foregroundColor, value: markerColor, range: line.markerRange)
            }
        } else {
            firstLineX = squeeze(line.indentation, before: contentX, in: storage, tabStops: &tabStops)
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = firstLineX
        paragraph.headIndent = contentX
        paragraph.tabStops = tabStops.map { NSTextTab(textAlignment: .natural, location: $0) }
        paragraph.defaultTabInterval = Self.defaultTabInterval
        storage.addAttribute(.paragraphStyle, value: paragraph, range: paragraphRange(of: line, in: string))
    }

    // The whitespace right before the marker and the text keeps its width (or
    // tab stop), so the caret there is where the next glyph is drawn: CoreText
    // puts the caret after a kerned character in the middle of its kern.

    /// Lays out the indentation `range` so the character after it starts at
    /// `end`. Returns the first-line indent this needs.
    private func squeeze(_ range: NSRange, before end: CGFloat, in storage: NSTextStorage, tabStops: inout [CGFloat]) -> CGFloat {
        guard range.length > 0 else { return end }
        let last = range.upperBound - 1
        let body = NSRange(location: range.location, length: last - range.location)
        let start = end - spaceWidth - CGFloat(tabCount(in: body, of: storage.mutableString)) * Self.squeezedTab
        squeeze(body, from: start, in: storage, tabStops: &tabStops)
        if storage.mutableString.character(at: last) == Self.tab {
            tabStops.append(end)
        }
        return start
    }

    /// Lays out the whitespace `range` after a marker that ends at `start`, so
    /// the text after it starts at `end`.
    private func stretch(_ range: NSRange, from start: CGFloat, to end: CGFloat, in storage: NSTextStorage, tabStops: inout [CGFloat]) {
        guard range.length > 0 else { return }
        let string = storage.mutableString
        let last = range.upperBound - 1
        let tabs = squeeze(NSRange(location: range.location, length: last - range.location), from: start, in: storage, tabStops: &tabStops)
        if string.character(at: last) == Self.tab {
            tabStops.append(end)
            return
        }
        // The rest of the distance goes before the last space: onto the
        // previous tab's stop, or the previous character's kern.
        let extra = end - spaceWidth - start - CGFloat(tabs) * Self.squeezedTab
        if last > range.location, string.character(at: last - 1) == Self.tab {
            tabStops[tabStops.count - 1] += extra
        } else {
            let kern = storage.attribute(.kern, at: last - 1, effectiveRange: nil) as? CGFloat ?? 0
            storage.addAttribute(.kern, value: kern + extra, range: NSRange(location: last - 1, length: 1))
        }
    }

    /// Makes the spaces in `range` take no room and adds a tab stop for each
    /// tab, `squeezedTab` apart from just after `x`. Returns the number of tabs.
    @discardableResult
    private func squeeze(_ range: NSRange, from x: CGFloat, in storage: NSTextStorage, tabStops: inout [CGFloat]) -> Int {
        let string = storage.mutableString
        var tabs = 0
        for index in range.location..<range.upperBound {
            if string.character(at: index) == Self.tab {
                tabs += 1
                tabStops.append(x + CGFloat(tabs) * Self.squeezedTab)
            } else {
                storage.addAttribute(.kern, value: -spaceWidth, range: NSRange(location: index, length: 1))
            }
        }
        return tabs
    }

    private func tabCount(in range: NSRange, of string: NSString) -> Int {
        (range.location..<range.upperBound).count { string.character(at: $0) == Self.tab }
    }

    private static let tab: unichar = 0x09

    /// The line with its line break, so the paragraph style covers the paragraph.
    private func paragraphRange(of line: MarkdownListLine, in string: NSString) -> NSRange {
        var end = line.range.upperBound
        if end < string.length, string.character(at: end) == 0x0D { end += 1 }
        if end < string.length, string.character(at: end) == 0x0A { end += 1 }
        return NSRange(location: line.range.location, length: end - line.range.location)
    }

    private mutating func width(of marker: String) -> CGFloat {
        if let width = markerWidths[marker] { return width }
        let width = Self.width(of: marker, font: font)
        markerWidths[marker] = width
        return width
    }

    private static func width(of text: String, font: NSFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}

/// The bullet `ListItemLayoutFragment` draws over an unordered item's hidden
/// marker, centred on where the marker is laid out.
final class ListBulletDecoration: NSObject, @unchecked Sendable {
    /// The marker's UTF-16 offset in its paragraph.
    let markerOffset: Int
    let markerWidth: CGFloat
    let diameter: CGFloat
    /// How far the bullet's centre is above the baseline.
    let raise: CGFloat
    let color: NSColor

    init(markerOffset: Int, markerWidth: CGFloat, diameter: CGFloat, raise: CGFloat, color: NSColor) {
        self.markerOffset = markerOffset
        self.markerWidth = markerWidth
        self.diameter = diameter
        self.raise = raise
        self.color = color
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ListBulletDecoration else { return false }
        return markerOffset == other.markerOffset && markerWidth == other.markerWidth
            && diameter == other.diameter && raise == other.raise && color == other.color
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(markerOffset)
        hasher.combine(markerWidth)
        hasher.combine(diameter)
        return hasher.finalize()
    }
}

/// The layout fragment of an unordered list item's line: its text plus a
/// solid bullet in place of the hidden source marker.
final class ListItemLayoutFragment: NSTextLayoutFragment, @unchecked Sendable {
    let decoration: ListBulletDecoration

    init(textElement: NSTextElement, range: NSTextRange?, decoration: ListBulletDecoration) {
        self.decoration = decoration
        super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    /// The bullet in the fragment's coordinates, nil before layout.
    var bulletRect: CGRect? {
        guard let line = textLineFragments.first,
              NSLocationInRange(decoration.markerOffset, line.characterRange) else { return nil }
        let x = line.typographicBounds.minX + line.locationForCharacter(at: decoration.markerOffset).x + decoration.markerWidth / 2
        let y = line.typographicBounds.minY + line.glyphOrigin.y - decoration.raise
        let radius = decoration.diameter / 2
        return CGRect(x: x - radius, y: y - radius, width: decoration.diameter, height: decoration.diameter)
    }

    override var renderingSurfaceBounds: CGRect {
        let bounds = super.renderingSurfaceBounds
        guard let bullet = bulletRect else { return bounds }
        return bounds.union(bullet.insetBy(dx: -1, dy: -1))
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        guard let bullet = bulletRect else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        decoration.color.setFill()
        // Snapping the origin to a device pixel rasterizes every bullet the same, whatever the line's offset.
        var device = context.convertToDeviceSpace(bullet.offsetBy(dx: point.x, dy: point.y))
        device.origin = CGPoint(x: device.origin.x.rounded(), y: device.origin.y.rounded())
        NSBezierPath(ovalIn: context.convertToUserSpace(device)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
