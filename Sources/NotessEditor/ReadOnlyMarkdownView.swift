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
        return ceil(textHeight + textContainerInset.height * 2)
    }
}

/// Read-only Markdown with the editor's live formatting, as tall as its text,
/// e.g. one Section of a Tag Timeline. See `makeReadOnlyTextView(style:)`.
public struct ReadOnlyMarkdownView: NSViewRepresentable {
    private let markdown: String
    private let style: MarkdownEditorStyle

    /// - Parameters:
    ///   - fontName: The body font's PostScript name, or `"System"`.
    ///   - colors: Formatting colours; the defaults follow light/dark mode.
    public init(
        markdown: String,
        fontName: String = "System",
        fontSize: CGFloat = 15,
        colors: MarkdownEditorStyle.Colors = .init()
    ) {
        self.markdown = markdown
        self.style = MarkdownEditorStyle(fontName: fontName, fontSize: fontSize, colors: colors)
    }

    public func makeNSView(context: Context) -> MarkdownTextView {
        let textView = MarkdownTextViewFactory.makeReadOnlyTextView(style: style)
        textView.string = markdown
        return textView
    }

    public func updateNSView(_ textView: MarkdownTextView, context: Context) {
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
