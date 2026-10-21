import AppKit
import NotessCore
import SwiftUI

/// Builds the editor's AppKit view hierarchy: a `MarkdownTextView` on TextKit 2
/// inside a scroll view, configured for plain-text Markdown with live formatting.
///
/// Do not access `NSTextView.layoutManager` anywhere in the editor: AppKit
/// then silently falls back to TextKit 1 for that view.
@MainActor
public enum MarkdownTextViewFactory {
    public static func makeScrollView(style: MarkdownEditorStyle = .standard) -> NSScrollView {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        configure(textView)
        textView.attachHighlighter()
        textView.markdownStyle = style

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        return scrollView
    }

    static func configure(_ textView: NSTextView) {
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        // Cmd+F opens Notess's own find bar (EditorFind), not AppKit's, which offers replacement.
        textView.usesFindBar = false
        textView.isIncrementalSearchingEnabled = false
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 24, height: 20)

        // Markdown is literal text: typographic substitutions would corrupt it.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false

        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    }
}

/// A request to select and scroll to a range of a document's text, e.g. a
/// Section. Applied once per `id`, after the document is loaded into the editor.
public struct EditorReveal: Equatable {
    public let id: UUID
    public let documentID: AnyHashable
    /// UTF-16 range in the document's text.
    public let range: NSRange

    public init(id: UUID = UUID(), documentID: AnyHashable, range: NSRange) {
        self.id = id
        self.documentID = documentID
        self.range = range
    }
}

/// SwiftUI wrapper around the TextKit 2 Markdown editor.
///
/// The text view owns the text while the user types; SwiftUI is only told about
/// changes through `onTextChange`. Text is pushed *into* the view only when
/// `documentID` changes, so keystrokes never round-trip through SwiftUI.
public struct MarkdownEditor: NSViewRepresentable {
    private let documentID: AnyHashable
    private let style: MarkdownEditorStyle
    private let isEditable: Bool
    private let isInteractionEnabled: Bool
    private let initialText: () -> String
    private let reveal: EditorReveal?
    private let onOpenWikiLink: ((WikiLink) -> Void)?
    private let onTextChange: (String) -> Void
    private let noteURL: URL?
    private let onPasteImage: ((Data, String) -> String?)?
    private let onPasteImageFailure: ((Error) -> Void)?
    private let inlineImageData: ((String) -> Data?)?
    private let onOpenImagePreview: ((ImagePreviewContent) -> Void)?
    private let onImageLoadFailure: ((String) -> Void)?
    private let onMagnify: ((CGFloat) -> Void)?
    private let tagSuggestionSource: TagSuggestionSource?
    private let onTagSuggestionFailure: ((Error) -> Void)?

    /// - Parameters:
    ///   - fontName: The body font's PostScript name, or `"System"`.
    ///   - fontSize: The body font size to display, i.e. already scaled by any text zoom.
    ///   - onMagnify: Receives the incremental magnification of a trackpad pinch over the editor.
    ///   - tagSuggestionSource: Saved Tags offered while typing a Tag; nil turns Tag completion off.
    ///   - onTagSuggestionFailure: Told when looking up Tag suggestions fails (once until one succeeds).
    ///   - colors: Formatting colours; the defaults follow light/dark mode.
    public init(
        documentID: AnyHashable,
        initialText: @escaping () -> String,
        fontName: String = "System",
        fontSize: CGFloat = 15,
        colors: MarkdownEditorStyle.Colors = .init(),
        reveal: EditorReveal? = nil,
        onOpenWikiLink: ((WikiLink) -> Void)? = nil,
        isEditable: Bool = true,
        isInteractionEnabled: Bool = true,
        noteURL: URL? = nil,
        onPasteImage: ((Data, String) -> String?)? = nil,
        onPasteImageFailure: ((Error) -> Void)? = nil,
        inlineImageData: ((String) -> Data?)? = nil,
        onOpenImagePreview: ((ImagePreviewContent) -> Void)? = nil,
        onImageLoadFailure: ((String) -> Void)? = nil,
        onMagnify: ((CGFloat) -> Void)? = nil,
        tagSuggestionSource: TagSuggestionSource? = nil,
        onTagSuggestionFailure: ((Error) -> Void)? = nil,
        onTextChange: @escaping (String) -> Void
    ) {
        self.documentID = documentID
        self.style = MarkdownEditorStyle(fontName: fontName, fontSize: fontSize, colors: colors)
        self.isEditable = isEditable
        self.isInteractionEnabled = isInteractionEnabled
        self.initialText = initialText
        self.reveal = reveal
        self.onOpenWikiLink = onOpenWikiLink
        self.noteURL = noteURL
        self.onPasteImage = onPasteImage
        self.onPasteImageFailure = onPasteImageFailure
        self.inlineImageData = inlineImageData
        self.onOpenImagePreview = onOpenImagePreview
        self.onImageLoadFailure = onImageLoadFailure
        self.onMagnify = onMagnify
        self.tagSuggestionSource = tagSuggestionSource
        self.onTagSuggestionFailure = onTagSuggestionFailure
        self.onTextChange = onTextChange
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = MarkdownTextViewFactory.makeScrollView(style: style)
        let textView = scrollView.documentView as! MarkdownTextView
        textView.delegate = context.coordinator
        configureImages(in: textView)
        configureTagCompletion(in: textView)
        context.coordinator.onTextChange = onTextChange
        textView.onWikiLinkClick = onOpenWikiLink
        textView.onMagnify = onMagnify
        configureInteraction(in: textView, coordinator: context.coordinator)
        load(into: textView, coordinator: context.coordinator)
        applyReveal(to: textView, coordinator: context.coordinator)
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onTextChange = onTextChange
        guard let textView = scrollView.documentView as? MarkdownTextView else { return }
        textView.onWikiLinkClick = onOpenWikiLink
        textView.onMagnify = onMagnify
        configureImages(in: textView)
        configureTagCompletion(in: textView)
        if textView.markdownStyle != style {
            textView.markdownStyle = style
        }
        configureInteraction(in: textView, coordinator: context.coordinator)
        if context.coordinator.documentID != documentID {
            load(into: textView, coordinator: context.coordinator)
        }
        applyReveal(to: textView, coordinator: context.coordinator)
    }

    private func applyReveal(to textView: NSTextView, coordinator: Coordinator) {
        guard let reveal, reveal.documentID == documentID, coordinator.lastRevealID != reveal.id else { return }
        coordinator.lastRevealID = reveal.id
        let length = (textView.string as NSString).length
        guard reveal.range.location <= length else { return }
        let range = NSRange(location: reveal.range.location, length: min(reveal.range.length, length - reveal.range.location))
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
        DispatchQueue.main.async {
            textView.scrollRangeToVisible(range)
        }
    }

    private func load(into textView: MarkdownTextView, coordinator: Coordinator) {
        coordinator.documentID = documentID
        textView.string = initialText()
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.scheduleInlineImageRefresh()
        guard isEditable && isInteractionEnabled else { return }
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            textView.scrollRangeToVisible(textView.selectedRange())
        }
    }

    private func configureImages(in textView: MarkdownTextView) {
        textView.onPasteImage = onPasteImage
        textView.onPasteImageFailure = onPasteImageFailure
        textView.inlineImageData = inlineImageData
        textView.onOpenImagePreview = onOpenImagePreview
        textView.onImageLoadFailure = onImageLoadFailure
        textView.noteURL = noteURL
    }

    private func configureTagCompletion(in textView: MarkdownTextView) {
        textView.tagSuggestionSource = tagSuggestionSource
        textView.onTagSuggestionFailure = onTagSuggestionFailure
    }

    private func configureInteraction(in textView: MarkdownTextView, coordinator: Coordinator) {
        let wasInteractionEnabled = coordinator.isInteractionEnabled
        coordinator.isInteractionEnabled = isInteractionEnabled
        textView.isEditable = isEditable && isInteractionEnabled
        textView.isSelectable = isInteractionEnabled
        guard isInteractionEnabled, wasInteractionEnabled == false else { return }
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var documentID: AnyHashable?
        var lastRevealID: UUID?
        var isInteractionEnabled: Bool?
        var onTextChange: (String) -> Void = { _ in }

        public func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            onTextChange(textView.string)
        }
    }
}
