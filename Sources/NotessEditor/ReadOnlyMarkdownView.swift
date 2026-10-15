import AppKit
import SwiftUI

extension MarkdownTextViewFactory {
    /// A `MarkdownTextView` that shows Markdown with live formatting but cannot
    /// change it: text can be selected and copied; typing, pasting, undo and
    /// task checkboxes do nothing. It has no scroll view of its own, so it can
    /// sit in a longer scrolling list; size it with `fittingHeight(forWidth:)`.
    public static func makeReadOnlyTextView(style: MarkdownEditorStyle = .standard) -> MarkdownTextView {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        configure(textView)
        textView.attachHighlighter()
        textView.markdownStyle = style
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.usesFindBar = false
        textView.isIncrementalSearchingEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.autoresizingMask = []
        return textView
    }
}

extension MarkdownTextView {
    /// The height that shows all of the text when the view is `width` wide.
    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        if abs(frame.width - width) > 0.5 {
            setFrameSize(NSSize(width: width, height: frame.height))
        }
        guard let textLayoutManager else { return 0 }
        textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
        let textHeight = textLayoutManager.usageBoundsForTextContainer.height
        return ceil(textHeight + trailingInlineImageHeight + textContainerInset.height * 2)
    }
}

/// Read-only Markdown with the editor's live formatting, as tall as its text,
/// e.g. one Section of a Tag Timeline. See `makeReadOnlyTextView(style:)`.
public struct ReadOnlyMarkdownView: NSViewRepresentable {
    private let markdown: String
    private let style: MarkdownEditorStyle
    private let noteURL: URL?
    private let onOpenImagePreview: ((ImagePreviewContent) -> Void)?
    private let onImageLoadFailure: ((String) -> Void)?
    @State private var imageLayoutTick = 0

    /// - Parameters:
    ///   - noteURL: The saved note the Markdown comes from. Relative images
    ///     resolve against its directory and are read from disk, never from staged bytes.
    ///   - onOpenImagePreview: Called with the clicked image for the shared preview.
    ///   - onImageLoadFailure: Called with a message when an image cannot be loaded.
    ///   - fontName: The body font's PostScript name, or `"System"`.
    ///   - colors: Formatting colours; the defaults follow light/dark mode.
    public init(
        markdown: String,
        fontName: String = "System",
        fontSize: CGFloat = 15,
        colors: MarkdownEditorStyle.Colors = .init(),
        noteURL: URL? = nil,
        onOpenImagePreview: ((ImagePreviewContent) -> Void)? = nil,
        onImageLoadFailure: ((String) -> Void)? = nil
    ) {
        self.noteURL = noteURL
        self.onOpenImagePreview = onOpenImagePreview
        self.onImageLoadFailure = onImageLoadFailure
        self.markdown = markdown
        self.style = MarkdownEditorStyle(fontName: fontName, fontSize: fontSize, colors: colors)
    }

    public func makeNSView(context: Context) -> MarkdownTextView {
        let textView = MarkdownTextViewFactory.makeReadOnlyTextView(style: style)
        configureImages(in: textView)
        textView.string = markdown
        return textView
    }

    private func configureImages(in textView: MarkdownTextView) {
        textView.onOpenImagePreview = onOpenImagePreview
        textView.onImageLoadFailure = onImageLoadFailure
        let tick = $imageLayoutTick
        // Deferred: this fires during AppKit layout, possibly inside a SwiftUI update.
        textView.onInlineImagesLaidOut = {
            DispatchQueue.main.async { tick.wrappedValue += 1 }
        }
        textView.noteURL = noteURL
    }

    public func updateNSView(_ textView: MarkdownTextView, context: Context) {
        _ = imageLayoutTick // re-measure the height once images changed it
        configureImages(in: textView)
        if textView.markdownStyle != style {
            textView.markdownStyle = style
        }
        if textView.string != markdown {
            textView.string = markdown
        }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView textView: MarkdownTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: textView.fittingHeight(forWidth: width))
    }
}
