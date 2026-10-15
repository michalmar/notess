import AppKit
import NotessCore
import UniformTypeIdentifiers

/// The editor's `NSTextView`: live Markdown formatting and clickable task boxes.
///
/// Do not access `layoutManager` here: it switches the view to TextKit 1.
public final class MarkdownTextView: NSTextView {
    let highlighter = MarkdownHighlighter()
    public var onPasteImage: ((Data, String) -> String?)?
    public var inlineImageData: ((String) -> Data?)?
    public var onOpenImagePreview: ((ImagePreviewContent) -> Void)?
    public var onImageLoadFailure: ((String) -> Void)?
    /// Called after inline images changed the height the text needs.
    var onInlineImagesLaidOut: (() -> Void)?
    public var noteURL: URL? {
        didSet {
            guard oldValue != noteURL else { return }
            imageCache.removeAll()
            reportedImageFailures.removeAll()
            scheduleInlineImageRefresh()
        }
    }

    @MainActor
    private final class InlineImageView: NSImageView {
        var onClick: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            onClick?()
        }
    }

    @MainActor
    private final class InlineImagePreview {
        let source: String
        var range: NSRange
        var paragraphRange: NSRange
        let image: NSImage
        let imageView = InlineImageView()

        init(source: String, range: NSRange, paragraphRange: NSRange, image: NSImage) {
            self.source = source
            self.range = range
            self.paragraphRange = paragraphRange
            self.image = image
        }
    }

    private var inlineImagePreviews: [InlineImagePreview] = []
    private var imageCache: [String: NSImage] = [:]
    private var reportedImageFailures: Set<String> = []

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
        observeUndoAndRedo()
        highlighter.didStyleText = { [weak self] range, editedRange, delta in
            guard let self else { return }
            if let editedRange {
                hasUnreportedTextEdit = true
                updateInlineImages(in: range, editedRange: editedRange, changeInLength: delta)
            } else {
                refreshInlineImages()
            }
        }
        textStorage?.delegate = highlighter
        font = highlighter.style.font
        typingAttributes = highlighter.baseAttributes
    }

    // MARK: Change reporting

    /// True after a character edit the delegate has not been told about yet.
    private var hasUnreportedTextEdit = false

    public override var string: String {
        get { super.string }
        set {
            super.string = newValue
            hasUnreportedTextEdit = false
        }
    }

    public override func didChangeText() {
        hasUnreportedTextEdit = false
        super.didChangeText()
    }

    /// On TextKit 2, undo and redo change the text without `didChangeText()`,
    /// so the delegate (and the note's unsaved state) would miss them.
    private func observeUndoAndRedo() {
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(undoManagerDidChangeText(_:)),
                name: name,
                object: nil
            )
        }
    }

    @objc private func undoManagerDidChangeText(_ notification: Notification) {
        guard hasUnreportedTextEdit,
              let undoManager,
              notification.object as? UndoManager === undoManager else { return }
        didChangeText()
    }

    public override func mouseDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
        if event.clickCount == 1, modifiers.isEmpty,
           toggleTask(atPoint: convert(event.locationInWindow, from: nil)) {
            return
        }
        if event.clickCount == 1, modifiers.isEmpty,
           openInlineImage(atPoint: convert(event.locationInWindow, from: nil)) {
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

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(frame.size.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            scheduleInlineImageLayout(updateSpacing: true)
        }
    }

    // MARK: Image paste

    /// Called when clipboard image data cannot be turned into a PNG; nothing is inserted.
    public var onPasteImageFailure: ((Error) -> Void)?

    /// The pasteboard Paste reads; tests substitute a private one.
    var pasteboard: NSPasteboard = .general

    /// The Edit ▸ Paste item (and so Cmd+V) is enabled by AppKit only for the
    /// types a plain-text view reads, which exclude images: without this, Paste
    /// stays disabled for a screenshot on the clipboard and `paste(_:)` never runs.
    public override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        validatePaste(item.action) ?? super.validateUserInterfaceItem(item)
    }

    public override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        validatePaste(menuItem.action) ?? super.validateMenuItem(menuItem)
    }

    /// Whether Paste is enabled, or `nil` to leave the decision to AppKit.
    private func validatePaste(_ action: Selector?) -> Bool? {
        guard action == #selector(paste(_:)) else { return nil }
        if canPasteImage { return true }
        // AppKit validates against the general pasteboard only.
        guard pasteboard != .general else { return nil }
        return isEditable && pasteboard.availableType(from: readablePasteboardTypes) != nil
    }

    /// Pastes clipboard image data as a Markdown image on its own line; text
    /// (including text that comes with an image preview) pastes as usual.
    public override func paste(_ sender: Any?) {
        guard canPasteImage, let onPasteImage else {
            pasteText(sender)
            return
        }
        guard let png = Self.pngData(from: pasteboard) else {
            NSSound.beep()
            onPasteImageFailure?(ImagePasteError.unreadableImage)
            return
        }
        guard let markdown = onPasteImage(png, "png") else {
            pasteText(sender)
            return
        }
        let range = selectedRange()
        let replacement = NoteAttachment.standaloneLine(markdown, replacing: range, in: string)
        replace(range, with: replacement, actionName: "Vložit obrázek")
    }

    private func pasteText(_ sender: Any?) {
        if pasteboard == .general {
            super.paste(sender)
        } else {
            readSelection(from: pasteboard)
        }
    }

    /// True when Paste would insert an image: the view is editable, has an image
    /// handler, and the clipboard holds image data but no plain text. Files
    /// copied in Finder are not images to paste.
    private var canPasteImage: Bool {
        guard isEditable, onPasteImage != nil, let types = pasteboard.types else { return false }
        guard !types.contains(.string), !types.contains(.fileURL) else { return false }
        return types.contains { Self.isImageType($0) }
    }

    private static func isImageType(_ type: NSPasteboard.PasteboardType) -> Bool {
        UTType(type.rawValue)?.conforms(to: .image) == true
    }

    /// The clipboard image as PNG: PNG data as is, any other image type converted losslessly.
    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let data = pasteboard.data(forType: .png), NSBitmapImageRep(data: data) != nil {
            return data
        }
        for type in pasteboard.types ?? [] where type != .png && isImageType(type) {
            if let data = pasteboard.data(forType: type),
               let bitmap = NSBitmapImageRep(data: data),
               let png = bitmap.representation(using: .png, properties: [:]) {
                return png
            }
        }
        return nil
    }

    /// Replaces `range` like typing would (undoable as one step, notifies the
    /// delegate) and puts the caret after the new text.
    @discardableResult
    private func replace(_ range: NSRange, with replacement: String, actionName: String) -> Bool {
        guard let textStorage, shouldChangeText(in: range, replacementString: replacement) else {
            return false
        }
        breakUndoCoalescing()
        textStorage.replaceCharacters(in: range, with: replacement)
        didChangeText()
        breakUndoCoalescing()
        setSelectedRange(NSRange(location: range.location + (replacement as NSString).length, length: 0))
        undoManager?.setActionName(actionName)
        scrollRangeToVisible(selectedRange())
        return true
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
        onInlineImagesLaidOut?()
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
        onInlineImagesLaidOut?()
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
            preview.imageView.onClick = { [weak self, weak preview] in
                guard let self, let preview else { return }
                self.open(preview)
            }
            self.addSubview(preview.imageView)
            self.inlineImagePreviews.append(preview)
        }
    }

    /// Space the last paragraph's images need below it. TextKit does not count
    /// paragraph spacing after the final paragraph in its usage bounds.
    var trailingInlineImageHeight: CGFloat {
        guard let length = textStorage?.length else { return 0 }
        return inlineImagePreviews
            .filter { $0.paragraphRange.upperBound >= length }
            .reduce(0) { $0 + fittedSize(for: $1.image).height + 8 }
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
        guard isSafeRelativePath(decoded) else {
            reportImageLoadFailure(source: source)
            return nil
        }
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
            reportedImageFailures.remove(source)
        } else {
            reportImageLoadFailure(source: source)
        }
        return image
    }

    private func reportImageLoadFailure(source: String) {
        guard reportedImageFailures.insert(source).inserted else { return }
        onImageLoadFailure?("Obrázek „\(source)“ se nepodařilo načíst.")
    }

    private func openInlineImage(atPoint point: NSPoint) -> Bool {
        guard let preview = inlineImagePreviews.first(where: {
            $0.imageView.frame.contains(point)
        }) else { return false }
        open(preview)
        return true
    }

    private func open(_ preview: InlineImagePreview) {
        onOpenImagePreview?(
            ImagePreviewContent(source: preview.source, image: preview.image)
        )
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
