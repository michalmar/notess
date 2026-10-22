import AppKit
import NotessCore

/// The standard pointing-hand cursor over the editor's interactive targets.
///
/// One cursor-rect set serves every target (links and heading disclosure
/// buttons, over each button's existing clickable frame). `NSTextView` still supplies the text cursor everywhere else, so
/// leaving a target restores the cursor the text view would show anyway.
/// Hovering is cursor-only: clicks, selection and folding are unchanged.
extension MarkdownTextView {
    /// Asks AppKit to rebuild the cursor rects (`resetCursorRects()`) before the
    /// next mouse move; call after anything that can move or remove a target.
    func invalidatePointingHandTargets() {
        window?.invalidateCursorRects(for: self)
    }

    /// Whether the pointing hand shows at `point` (view coordinates).
    func pointingHandTarget(containing point: NSPoint) -> Bool {
        pointingHandRects().contains { $0.contains(point) }
    }

    /// The visible areas, in view coordinates, that show the pointing hand.
    func pointingHandRects() -> [NSRect] {
        headingFolding.visibleButtonFrames + linkPointingHandRects()
    }

    /// The activation areas of links that are interactive right now: those
    /// with an activation callback, outside code and image syntax (the same
    /// recognition `mouseDown` uses), not folded away, and on screen.
    private func linkPointingHandRects() -> [NSRect] {
        guard textStorage != nil, onOpenWebLink != nil || onWikiLinkClick != nil else { return [] }
        let links = interactiveLinkRanges()
        guard !links.isEmpty else { return [] }

        // Without a scroll view the whole text is on screen; AppKit clips
        // cursor rects to the visible area of enclosing views itself.
        var visible = NSRange(location: 0, length: (string as NSString).length)
        var clip: NSRect?
        if enclosingScrollView != nil {
            let area = visibleRect
            // Probe inside the text container: points in the inset resolve to the end of the text.
            let origin = textContainerOrigin
            let first = characterIndexForInsertion(at: NSPoint(x: origin.x + 1, y: max(area.minY, origin.y + 1)))
            let last = characterIndexForInsertion(at: NSPoint(x: area.maxX - origin.x - 1, y: area.maxY))
            visible = NSRange(location: min(first, last), length: abs(last - first) + 1)
            clip = area
        }

        var rects: [NSRect] = []
        for range in links where NSIntersectionRange(range, visible).length > 0 && !headingFolding.hides(range.location) {
            for frame in segmentFrames(of: range) {
                // The same slack `webLink(atPoint:)` and `wikiLink(atPoint:)` allow around the text.
                var rect = frame.insetBy(dx: -2, dy: -2)
                if let clip { rect = rect.intersection(clip) }
                if !rect.isEmpty { rects.append(rect) }
            }
        }
        return rects
    }

    private func interactiveLinkRanges() -> [NSRange] {
        let text = string
        if linkCache.text != text {
            linkCache = LinkCache(
                text: text,
                web: WebLink.links(in: text).map(\.range),
                wiki: text.contains("[[") ? WikiLink.links(in: text).map(\.range) : []
            )
        }
        return (onOpenWebLink != nil ? linkCache.web : []) + (onWikiLinkClick != nil ? linkCache.wiki : [])
    }

    /// The line-by-line frames of `range` in view coordinates, from TextKit 2 layout.
    private func segmentFrames(of range: NSRange) -> [NSRect] {
        guard let manager = textLayoutManager,
              let content = manager.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return [] }
        var frames: [NSRect] = []
        manager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            frames.append(frame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y))
            return true
        }
        return frames
    }
}

/// Link ranges for one version of the text, so cursor rects rebuilt on every
/// scroll and layout do not re-parse the note.
struct LinkCache {
    var text: String?
    var web: [NSRange] = []
    var wiki: [NSRange] = []
}
