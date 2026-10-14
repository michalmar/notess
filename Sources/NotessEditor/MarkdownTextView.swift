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
        didSet {
            guard oldValue != noteURL else { return }
            imageCache.removeAll()
            scheduleInlineImageRefresh()
        }
    }

    @MainActor
    private final class InlineImagePreview {
        let source: String
        var range: NSRange
        var paragraphRange: NSRange
        let image: NSImage
        let imageView = NSImageView()

        init(source: String, range: NSRange, paragraphRange: NSRange, image: NSImage) {
            self.source = source
            self.range = range
            self.paragraphRange = paragraphRange
            self.image = image
        }
    }

    private var inlineImagePreviews: [InlineImagePreview] = []
    private var imageCache: [String: NSImage] = [:]

    var displayedInlineImageCount: Int { inlineImagePreviews.count }

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
        highlighter.didStyleText = { [weak self] range, editedRange, delta in
            guard let self else { return }
            if let editedRange {
                updateInlineImages(in: range, editedRange: editedRange, changeInLength: delta)
            } else {
                refreshInlineImages()
            }
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
            scheduleInlineImageLayout(updateSpacing: true)
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

        for preview in inlineImagePreviews {
            if preview.paragraphRange.upperBound <= textStorage.length {
                textStorage.removeAttribute(.paragraphStyle, range: preview.paragraphRange)
            }
            preview.imageView.removeFromSuperview()
        }
        inlineImagePreviews.removeAll()

        guard let noteURL, textStorage.length > 0 else { return }
        addInlineImagePreviews(
            in: NSRange(location: 0, length: textStorage.length),
            noteURL: noteURL
        )
        updateParagraphSpacing(for: Set(inlineImagePreviews.map(\.paragraphRange)))
        layoutInlineImageViews()
    }

    private func updateInlineImages(
        in styledRange: NSRange,
        editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard let textStorage, let noteURL else { return }
        let oldRange = NSRange(
            location: editedRange.location,
            length: max(0, editedRange.length - delta)
        )
        let removedByEdit = inlineImagePreviews.filter {
            NSIntersectionRange($0.range, oldRange).length > 0
        }
        let oldEnd = oldRange.upperBound
        for preview in inlineImagePreviews
        where !removedByEdit.contains(where: { $0 === preview }) && preview.range.location >= oldEnd {
            preview.range.location += delta
            preview.paragraphRange.location += delta
        }

        let removedByStyling = inlineImagePreviews.filter {
            NSIntersectionRange($0.range, styledRange).length > 0
        }
        let removed = removedByEdit + removedByStyling.filter { candidate in
            !removedByEdit.contains { $0 === candidate }
        }
        for preview in removed {
            preview.imageView.removeFromSuperview()
        }
        inlineImagePreviews.removeAll { preview in
            removed.contains { $0 === preview }
        }

        let range = NSIntersectionRange(
            styledRange,
            NSRange(location: 0, length: textStorage.length)
        )
        guard range.length > 0 else {
            scheduleInlineImageLayout()
            return
        }
        addInlineImagePreviews(in: range, noteURL: noteURL)
        let paragraphs = Set(inlineImagePreviews.compactMap { preview in
            NSIntersectionRange(preview.paragraphRange, range).length > 0
                ? preview.paragraphRange
                : nil
        })
        updateParagraphSpacing(for: paragraphs)
        scheduleInlineImageLayout()
    }

    private func addInlineImagePreviews(in range: NSRange, noteURL: URL) {
        guard let textStorage else { return }
        let string = textStorage.string as NSString
        textStorage.enumerateAttribute(.notessImageSource, in: range) { value, imageRange, _ in
            guard let source = value as? String,
                  let image = self.image(source: source, noteURL: noteURL) else { return }
            let paragraphRange = string.paragraphRange(for: imageRange)
            let preview = InlineImagePreview(
                source: source,
                range: imageRange,
                paragraphRange: paragraphRange,
                image: image
            )
            preview.imageView.image = image
            preview.imageView.imageScaling = .scaleProportionallyUpOrDown
            preview.imageView.isEditable = false
            self.addSubview(preview.imageView)
            self.inlineImagePreviews.append(preview)
        }
    }

    private func updateParagraphSpacing(for paragraphRanges: Set<NSRange>) {
        guard let textStorage else { return }
        for paragraphRange in paragraphRanges where paragraphRange.upperBound <= textStorage.length {
            let previews = inlineImagePreviews.filter { $0.paragraphRange == paragraphRange }
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = previews.reduce(0) {
                $0 + fittedSize(for: $1.image).height + 8
            }
            textStorage.addAttribute(.paragraphStyle, value: style, range: paragraphRange)
        }
    }

    private func scheduleInlineImageLayout(updateSpacing: Bool = false) {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(layoutInlineImageViews),
            object: nil
        )
        if updateSpacing {
            updateParagraphSpacing(for: Set(inlineImagePreviews.map(\.paragraphRange)))
        }
        perform(#selector(layoutInlineImageViews), with: nil, afterDelay: 0)
    }

    @objc private func layoutInlineImageViews() {
        layoutSubtreeIfNeeded()
        var paragraphOffsets: [NSRange: CGFloat] = [:]
        for preview in inlineImagePreviews.sorted(by: { $0.range.location < $1.range.location }) {
            let size = fittedSize(for: preview.image)
            let lineRect = rect(forCharacterRange: preview.range)
            let offset = paragraphOffsets[preview.paragraphRange, default: 0]
            preview.imageView.frame = NSRect(
                x: lineRect.minX,
                y: lineRect.maxY + 8 + offset,
                width: size.width,
                height: size.height
            )
            paragraphOffsets[preview.paragraphRange] = offset + size.height + 8
        }
    }

    private func image(source: String, noteURL: URL) -> NSImage? {
        if let cached = imageCache[source] {
            return cached
        }
        let unescaped = unescapeMarkdownPath(source)
        let decoded = unescaped.removingPercentEncoding ?? unescaped
        guard isSafeRelativePath(decoded) else { return nil }
        let image: NSImage?
        if let data = inlineImageData?(source) {
            image = NSImage(data: data)
        } else {
            let url = noteURL.deletingLastPathComponent()
                .appending(path: decoded, directoryHint: .notDirectory)
                .standardizedFileURL
            image = NSImage(contentsOf: url)
        }
        if let image {
            imageCache[source] = image
        }
        return image
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        return !path.hasPrefix("/")
            && URL(string: path)?.scheme == nil
    }

    private func unescapeMarkdownPath(_ path: String) -> String {
        var result = ""
        var escaping = false
        for character in path {
            if escaping {
                result.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        if escaping { result.append("\\") }
        return result
    }

    private func fittedSize(for image: NSImage) -> NSSize {
        guard image.size.width > 0, image.size.height > 0 else { return .zero }
        let availableWidth = max(120, bounds.width - textContainerInset.width * 2)
        let scale = min(1, min(availableWidth / image.size.width, 240 / image.size.height))
        return NSSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    private func rect(forCharacterRange range: NSRange) -> NSRect {
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
        rect(forCharacterRange: range)
    }
}
