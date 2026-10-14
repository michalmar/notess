import AppKit
import SwiftUI

/// Builds the editor's AppKit view hierarchy: an `NSTextView` on TextKit 2
/// inside a scroll view, configured for plain-text Markdown.
///
/// Do not access `NSTextView.layoutManager` anywhere in the editor: AppKit
/// then silently falls back to TextKit 1 for that view.
@MainActor
public enum MarkdownTextViewFactory {
    public static func makeScrollView() -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: true)
        configure(textView)

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
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = .textColor
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

/// SwiftUI wrapper around the TextKit 2 Markdown editor.
///
/// The text view owns the text while the user types; SwiftUI is only told about
/// changes through `onTextChange`. Text is pushed *into* the view only when
/// `documentID` changes, so keystrokes never round-trip through SwiftUI.
public struct MarkdownEditor: NSViewRepresentable {
    private let documentID: AnyHashable
    private let initialText: () -> String
    private let onTextChange: (String) -> Void
    private let fontName: String
    private let fontSize: CGFloat

    public init(
        documentID: AnyHashable,
        initialText: @escaping () -> String,
        fontName: String = "System",
        fontSize: CGFloat = 15,
        onTextChange: @escaping (String) -> Void
    ) {
        self.documentID = documentID
        self.initialText = initialText
        self.fontName = fontName
        self.fontSize = fontSize
        self.onTextChange = onTextChange
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = MarkdownTextViewFactory.makeScrollView()
        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        context.coordinator.onTextChange = onTextChange
        load(into: textView, coordinator: context.coordinator)
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onTextChange = onTextChange
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.font = resolvedFont()
        guard context.coordinator.documentID != documentID else { return }
        load(into: textView, coordinator: context.coordinator)
    }

    private func load(into textView: NSTextView, coordinator: Coordinator) {
        coordinator.documentID = documentID
        textView.string = initialText()
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            textView.scrollRangeToVisible(textView.selectedRange())
        }
    }

    private func resolvedFont() -> NSFont {
        guard fontName != "System", let font = NSFont(name: fontName, size: fontSize) else {
            return .systemFont(ofSize: fontSize)
        }
        return font
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var documentID: AnyHashable?
        var onTextChange: (String) -> Void = { _ in }

        public func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            onTextChange(textView.string)
        }
    }
}
