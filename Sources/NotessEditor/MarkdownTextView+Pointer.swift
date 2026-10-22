import AppKit
import NotessCore

/// The standard pointing-hand cursor over the editor's interactive targets.
///
/// One mechanism serves every target: links, Tags, and heading disclosure buttons
/// over each button's existing frame. `NSTextView` owns a `.cursorUpdate`
/// tracking area and re-applies the text cursor through it, which overrides
/// cursor rects, so the text view answers `cursorUpdate` and `mouseMoved`
/// itself. Cursor-only: clicks and folding are unchanged.
extension MarkdownTextView {
    /// Sets the pointing hand when `point` (view coordinates) is a target.
    /// Returns whether it is one; elsewhere the caller restores the text cursor.
    @discardableResult
    func updatePointingHand(at point: NSPoint) -> Bool {
        guard pointingHandTarget(containing: point) else { return false }
        NSCursor.pointingHand.set()
        return true
    }

    /// Replaces a pointing hand left behind by a target that is gone. Not
    /// `super.cursorUpdate`, which rejects mouse-moved events.
    func restoreTextCursor() {
        if NSCursor.current == .pointingHand, isSelectable { NSCursor.iBeam.set() }
    }

    /// Re-evaluates the cursor under a still mouse after anything that can move
    /// or remove a target (layout, scrolling, folding, edits).
    func refreshPointingHand() {
        guard let window, window.isKeyWindow, let content = window.contentView, let frameView = content.superview else { return }
        let windowPoint = window.mouseLocationOutsideOfEventStream
        let point = convert(windowPoint, from: nil)
        guard visibleRect.contains(point),
              let hit = content.hitTest(frameView.convert(windowPoint, from: nil)),
              hit === self || hit.isDescendant(of: self) else { return }
        if !updatePointingHand(at: point) { restoreTextCursor() }
    }

    /// Whether the pointing hand shows at `point` (view coordinates).
    func pointingHandTarget(containing point: NSPoint) -> Bool {
        pointingHandRects().contains { $0.contains(point) }
    }

    /// The visible areas, in view coordinates, that show the pointing hand.
    func pointingHandRects() -> [NSRect] {
        (isSelectable ? headingFolding.visibleButtonFrames : []) + linkPointingHandRects()
    }

    /// The activation areas of links and Tags that are interactive right now:
    /// those with an activation callback, outside code and image syntax (the
    /// same recognition `mouseDown` uses), not folded away, and on screen.
    private func linkPointingHandRects() -> [NSRect] {
        guard textStorage != nil, onOpenWebLink != nil || onWikiLinkClick != nil || onTagClick != nil else { return [] }
        let links = interactiveLinkRanges()
        guard !links.isEmpty else { return [] }

        // Without a scroll view the whole text is on screen.
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
                // The same slack `webLink(atPoint:)`, `wikiLink(atPoint:)` and `tag(atPoint:)` allow around the text.
                var rect = frame.insetBy(dx: -2, dy: -2)
                if let clip { rect = rect.intersection(clip) }
                if !rect.isEmpty { rects.append(rect) }
            }
        }
        return rects
    }

    private func interactiveLinkRanges() -> [NSRange] {
        refreshLinkCache()
        return (onOpenWebLink != nil ? linkCache.web : [])
            + (onWikiLinkClick != nil ? linkCache.wiki : [])
            + (onTagClick != nil ? cachedTags().map(\.range) : [])
    }

    /// The Tags of the current text, parsed once per version of the text.
    func cachedTags() -> [NotessCore.Tag] {
        refreshLinkCache()
        if let tags = linkCache.tags { return tags }
        let text = string
        let tags = text.contains("#") ? NotessCore.Tag.tags(in: text) : []
        linkCache.tags = tags
        return tags
    }

    private func refreshLinkCache() {
        let text = string
        guard linkCache.text != text else { return }
        linkCache = LinkCache(
            text: text,
            web: WebLink.links(in: text).map(\.range),
            wiki: text.contains("[[") ? WikiLink.links(in: text).map(\.range) : []
        )
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

/// Link ranges and Tags for one version of the text, so refreshing the cursor
/// on every mouse move, scroll and layout does not re-parse the note.
struct LinkCache {
    var text: String?
    var web: [NSRange] = []
    var wiki: [NSRange] = []
    /// Parsed on first use, only while Tags are clickable.
    var tags: [NotessCore.Tag]?
}
