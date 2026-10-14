import AppKit
import NotessCore

/// The editor's `NSTextView`: live Markdown formatting and clickable task boxes.
///
/// Do not access `layoutManager` here: it switches the view to TextKit 1.
public final class MarkdownTextView: NSTextView {
    let highlighter = MarkdownHighlighter()
    public var onPasteImage: ((Data, String) -> String?)?
    public var inlineImageData: ((String) -> Data?)?
    public var noteURL: URL? {
        didSet { scheduleInlineImageRefresh() }
    }

    private var inlineImageViews: [NSImageView] = []
    private var inlineImageSpacingRanges: [NSRange] = []

    var displayedInlineImageCount: Int { inlineImageViews.count }

    /// Called when the user clicks a `[[wiki-link]]`; the click then does not move the caret.
    public var onWikiLinkClick: ((WikiLink) -> Void)?

    /// Fonts and colours; setting a different style restyles the whole note.
    public var markdownStyle: MarkdownEditorStyle {
        get { highlighter.style }
        set {
            font = newValue.font
            if let textStorage {
                highlighter.setStyle(newValue, for: textStorage)
            }
            typingAttributes = highlighter.baseAttributes
        }
    }

    /// Connects the highlighter to the text storage; called once after creation.
    func attachHighlighter() {
        highlighter.didStyleText = { [weak self] in
            self?.scheduleInlineImageRefresh()
        }
        textStorage?.delegate = highlighter
        font = highlighter.style.font
        typingAttributes = highlighter.baseAttributes
    }

    public override func mouseDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
        if event.clickCount == 1, modifiers.isEmpty,
           toggleTask(atPoint: convert(event.locationInWindow, from: nil)) {
            return
        }
        if event.clickCount == 1, modifiers.isEmpty || modifiers == .command,
           let link = wikiLink(atPoint: convert(event.locationInWindow, from: nil)) {
            onWikiLinkClick?(link)
            return
        }
        super.mouseDown(with: event)
    }

    /// The wiki-link whose text lies under `point` (view coordinates), if any.
    func wikiLink(atPoint point: NSPoint) -> WikiLink? {
        guard onWikiLinkClick != nil, textStorage != nil, string.contains("[[") else { return nil }
        let index = characterIndexForInsertion(at: point)
        let candidates = [index, index - 1].filter { $0 >= 0 && $0 < (string as NSString).length }
        guard !candidates.isEmpty else { return nil }
        let links = WikiLink.links(in: string)
        for candidate in candidates {
            guard let link = links.first(where: { NSLocationInRange(candidate, $0.range) }),
                  boxRect(NSRange(location: candidate, length: 1)).insetBy(dx: -2, dy: -2).contains(point)
            else { continue }
            return link
        }
        return nil
    }

    public override func paste(_ sender: Any?) {
        paste(from: .general, fallback: { super.paste(sender) })
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(frame.size.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            scheduleInlineImageRefresh()
        }
    }

    func paste(from pasteboard: NSPasteboard) {
        paste(from: pasteboard, fallback: {})
    }

    private func paste(from pasteboard: NSPasteboard, fallback: () -> Void) {
        if let data = pngData(from: pasteboard),
           let markdown = onPasteImage?(data, "png") {
            insertText(markdown, replacementRange: selectedRange())
            return
        }
        if let text = pasteboard.string(forType: .string) {
            insertText(text, replacementRange: selectedRange())
            return
        }
        fallback()
    }

    private func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let data = pasteboard.data(forType: .png) {
            return data
        }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    func scheduleInlineImageRefresh() {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(refreshInlineImages),
            object: nil
        )
        perform(#selector(refreshInlineImages), with: nil, afterDelay: 0.05)
    }

    @objc func refreshInlineImages() {
        guard let textStorage else { return }

        for imageView in inlineImageViews {
            imageView.removeFromSuperview()
        }
        inlineImageViews.removeAll()
        for range in inlineImageSpacingRanges where range.upperBound <= textStorage.length {
            textStorage.removeAttribute(.paragraphStyle, range: range)
        }
        inlineImageSpacingRanges.removeAll()

        guard let noteURL, textStorage.length > 0 else { return }
        var images: [(range: NSRange, image: NSImage)] = []
        textStorage.enumerateAttribute(
            .notessImageSource,
            in: NSRange(location: 0, length: textStorage.length)
        ) { value, range, _ in
            guard let source = value as? String,
                  let image = self.image(source: source, noteURL: noteURL) else { return }
            images.append((range, image))
        }
        guard !images.isEmpty else { return }

        let string = textStorage.string as NSString
        let grouped = Dictionary(grouping: images) { item in
            string.paragraphRange(for: item.range)
        }
        var imageSizes: [NSRange: [NSSize]] = [:]
        for (paragraphRange, items) in grouped {
            let sizes = items.map { fittedSize(for: $0.image) }
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = sizes.reduce(0) { $0 + $1.height + 8 }
            textStorage.addAttribute(.paragraphStyle, value: style, range: paragraphRange)
            inlineImageSpacingRanges.append(paragraphRange)
            imageSizes[paragraphRange] = sizes
        }

        layoutSubtreeIfNeeded()
        var paragraphOffsets: [NSRange: CGFloat] = [:]
        for item in images {
            let paragraphRange = string.paragraphRange(for: item.range)
            let index = grouped[paragraphRange]?.firstIndex(where: { $0.range == item.range }) ?? 0
            let size = imageSizes[paragraphRange]?[index] ?? fittedSize(for: item.image)
            let lineRect = characterRect(item.range)
            let offset = paragraphOffsets[paragraphRange, default: 0]
            let imageView = NSImageView(frame: NSRect(
                x: lineRect.minX,
                y: lineRect.maxY + 8 + offset,
                width: size.width,
                height: size.height
            ))
            imageView.image = item.image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.isEditable = false
            addSubview(imageView)
            inlineImageViews.append(imageView)
            paragraphOffsets[paragraphRange] = offset + size.height + 8
        }
    }

    private func image(source: String, noteURL: URL) -> NSImage? {
        let decoded = source.removingPercentEncoding ?? source
        guard isSafeRelativePath(decoded) else { return nil }
        if let data = inlineImageData?(source), let image = NSImage(data: data) {
            return image
        }
        let url = noteURL.deletingLastPathComponent()
            .appending(path: decoded, directoryHint: .notDirectory)
        return NSImage(contentsOf: url)
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        let components = NSString(string: path).pathComponents
        return !path.hasPrefix("/")
            && !components.contains("..")
            && !components.contains(".")
            && URL(string: path)?.scheme == nil
    }

    private func fittedSize(for image: NSImage) -> NSSize {
        guard image.size.width > 0, image.size.height > 0 else { return .zero }
        let availableWidth = max(120, bounds.width - textContainerInset.width * 2)
        let scale = min(1, min(availableWidth / image.size.width, 240 / image.size.height))
        return NSSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    private func characterRect(_ range: NSRange) -> NSRect {
        guard let window else { return .zero }
        let screenRect = firstRect(forCharacterRange: range, actualRange: nil)
        return convert(window.convertFromScreen(screenRect), from: nil)
    }

    /// Toggles the task box under `point` (view coordinates), if any.
    func toggleTask(atPoint point: NSPoint) -> Bool {
        guard isEditable, let textStorage else { return false }
        let index = characterIndexForInsertion(at: point)
        for candidate in [index, index - 1] {
            guard let change = highlighter.lexer.taskToggle(at: candidate, in: textStorage.mutableString) else { continue }
            // The `[`, mark and `]` around the replaced mark.
            let box = NSRange(location: change.range.location - 1, length: 3)
            if boxRect(box).insetBy(dx: -2, dy: -2).contains(point) {
                return apply(change)
            }
        }
        return false
    }

    /// Toggles the `[ ]`/`[x]` box containing the character at `index`.
    /// Changes the text like typing would (undoable, marks the note as
    /// unsaved); nothing is written to disk.
    @discardableResult
    public func toggleTask(at index: Int) -> Bool {
        guard isEditable, let textStorage,
              let change = highlighter.lexer.taskToggle(at: index, in: textStorage.mutableString) else { return false }
        return apply(change)
    }

    private func apply(_ change: (range: NSRange, replacement: String)) -> Bool {
        guard let textStorage, shouldChangeText(in: change.range, replacementString: change.replacement) else {
            return false
        }
        breakUndoCoalescing()
        let selection = selectedRanges
        textStorage.replaceCharacters(in: change.range, with: change.replacement)
        didChangeText()
        selectedRanges = selection
        undoManager?.setActionName("Přepnout úkol")
        return true
    }

    /// The rectangle of `range` in view coordinates.
    private func boxRect(_ range: NSRange) -> NSRect {
        guard let window else { return .zero }
        let screenRect = firstRect(forCharacterRange: range, actualRange: nil)
        return convert(window.convertFromScreen(screenRect), from: nil)
    }
}
