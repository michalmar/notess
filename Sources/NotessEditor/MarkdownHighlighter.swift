import AppKit
import NotessCore

extension NSAttributedString.Key {
    static let notessImageSource = NSAttributedString.Key("NotessImageSource")
}

/// Live Markdown formatting for a text storage.
///
/// Acts as the `NSTextStorage` delegate: after every character edit it asks the
/// incremental `MarkdownLexer` which lines changed and restyles only those
/// (ADR 0001: typing must stay instant even in long notes). Markup stays
/// visible and is only dimmed, except in tables, which are drawn as a grid
/// (see `TableLayout`).
@MainActor
final class MarkdownHighlighter: NSObject, NSTextStorageDelegate, NSTextLayoutManagerDelegate {
    let lexer = MarkdownLexer()
    private(set) var headingTokens: [MarkdownToken] = []
    private(set) var style: MarkdownEditorStyle
    private var fontCache: [FontKey: NSFont] = [:]
    var didStyleText: (NSRange, NSRange?, Int) -> Void = { _, _, _ in }
    /// The editor's selection, nil in a view that never reports one (read-only).
    /// A table's delimiter row it touches shows its markup.
    private var selection: NSRange?
    /// The line of the delimiter row shown for `selection`.
    private var shownDelimiterRow: NSRange?

    init(style: MarkdownEditorStyle = .standard) {
        self.style = style
    }

    /// Changes the style and restyles the whole text.
    func setStyle(_ style: MarkdownEditorStyle, for storage: NSTextStorage) {
        self.style = style
        fontCache.removeAll()
        restyleAll(storage)
    }

    /// Re-lexes and restyles the whole text.
    func restyleAll(_ storage: NSTextStorage) {
        let update = lexer.relexAll(text: storage.mutableString)
        headingTokens = update.tokens.filter { if case .heading = $0.kind { true } else { false } }
        storage.beginEditing()
        apply(update, to: storage)
        storage.endEditing()
        didStyleText(NSRange(location: 0, length: storage.length), nil, 0)
    }

    /// Attributes of unformatted text; also the editor's typing attributes.
    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: style.font, .foregroundColor: style.colors.text]
    }

    // Styles in `didProcessEditing`, not `willProcessEditing`: on TextKit 2,
    // attributes set in `willProcessEditing` widen the edited range to the
    // restyled lines, and NSTextView then moves the caret to the end of them.
    nonisolated func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        // The editor's text storage is only ever edited on the main thread.
        nonisolated(unsafe) let storage = textStorage
        MainActor.assumeIsolated {
            // The caret ends up after the edit; the editor reports it only later.
            if selection != nil {
                selection = NSRange(location: editedRange.upperBound, length: 0)
            }
            let update = lexer.update(text: storage.mutableString, editedRange: editedRange, changeInLength: delta)
            let oldRange = NSRange(location: update.range.location, length: max(0, update.range.length - delta))
            headingTokens = headingTokens.compactMap { token in
                guard NSIntersectionRange(token.range, oldRange).length == 0 else { return nil }
                var token = token
                if token.range.location >= oldRange.upperBound { token.range.location += delta }
                return token
            }
            headingTokens += update.tokens.filter { if case .heading = $0.kind { true } else { false } }
            headingTokens.sort { $0.range.location < $1.range.location }
            apply(update, to: storage)
            // Attribute fixing (font fallback for emoji, CJK, ...) already ran
            // before this callback, and `apply` reset the fonts.
            if update.range.length > 0 { storage.fixAttributes(in: update.range) }
            didStyleText(update.range, editedRange, delta)
        }
    }

    /// Shows the delimiter row the selection moved onto and hides the one it left.
    func selectionDidChange(to range: NSRange, in storage: NSTextStorage) {
        selection = range
        let string = storage.mutableString
        var stale: [NSRange] = []
        if let shown = shownDelimiterRow, !TableLayout.selection(range, touches: shown, in: string) {
            stale.append(shown)
        }
        for location in Set([range.location, range.upperBound]) where location <= string.length {
            let line = string.lineRange(for: NSRange(location: location, length: 0))
            if line.length > 0,
               let row = storage.attribute(.notessTableRow, at: line.location, effectiveRange: nil) as? TableRowDecoration,
               row.kind == .delimiter {
                stale.append(line)
            }
        }
        for line in stale where line.upperBound <= string.length {
            let update = lexer.update(text: string, editedRange: line, changeInLength: 0)
            storage.beginEditing()
            apply(update, to: storage)
            if update.range.length > 0 { storage.fixAttributes(in: update.range) }
            storage.endEditing()
        }
    }

    /// Table rows get a fragment that draws the table grid.
    nonisolated func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph,
           paragraph.attributedString.length > 0,
           let decoration = paragraph.attributedString.attribute(.notessTableRow, at: 0, effectiveRange: nil) as? TableRowDecoration {
            return TableRowLayoutFragment(textElement: textElement, range: textElement.elementRange, decoration: decoration)
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }

    // MARK: Applying tokens

    private func apply(_ update: MarkdownLexer.Update, to storage: NSTextStorage) {
        guard update.range.length > 0 else { return }
        if let shown = shownDelimiterRow,
           shown.upperBound > storage.length || NSIntersectionRange(shown, update.range).length > 0 {
            shownDelimiterRow = nil
        }
        storage.setAttributes(baseAttributes, range: update.range)
        for layer in 0..<3 {
            for token in update.tokens where Self.layer(of: token.kind) == layer {
                apply(token, to: storage)
            }
        }
        for table in update.tables {
            if let shown = TableLayout.layOut(table, in: storage, style: style, showingDelimiterRowAt: selection) {
                shownDelimiterRow = shown
            }
        }
    }

    /// Block styles first, then inline styles, then the dimmed markup on top.
    private static func layer(of kind: MarkdownToken.Kind) -> Int {
        switch kind {
        case .heading, .codeBlock, .frontMatter, .blockquote, .tableHeader, .thematicBreak, .completedTask:
            0
        case .syntaxMarker:
            2
        default:
            1
        }
    }

    private func apply(_ token: MarkdownToken, to storage: NSTextStorage) {
        let range = token.range
        let colors = style.colors
        switch token.kind {
        case .heading(let level):
            let size = style.font.pointSize * MarkdownEditorStyle.headingScale(level)
            storage.addAttribute(.font, value: font(style.font, size: size, traits: .bold), range: range)
            applyHeadingSpacing(to: range, in: storage)
        case .codeBlock:
            storage.addAttributes([.font: style.codeFont, .backgroundColor: colors.codeBackground], range: range)
        case .frontMatter:
            storage.addAttributes([.font: style.codeFont, .foregroundColor: colors.syntaxMarker], range: range)
        case .blockquote:
            storage.addAttribute(.foregroundColor, value: colors.quote, range: range)
        case .tableHeader, .strong:
            addTraits(.bold, in: range, of: storage)
        case .emphasis:
            addTraits(.italic, in: range, of: storage)
        case .thematicBreak:
            storage.addAttribute(.foregroundColor, value: colors.syntaxMarker, range: range)
        case .completedTask:
            storage.addAttributes(
                [.foregroundColor: colors.completedTask, .strikethroughStyle: NSUnderlineStyle.single.rawValue],
                range: range
            )
        case .strikethrough:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .inlineCode:
            storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let current = value as? NSFont ?? style.font
                let size = style.codeFont.pointSize * current.pointSize / style.font.pointSize
                storage.addAttribute(.font, value: font(style.codeFont, size: size, traits: []), range: subrange)
            }
            storage.addAttribute(.backgroundColor, value: colors.codeBackground, range: range)
        case .link:
            storage.addAttributes(
                [.foregroundColor: colors.link, .underlineStyle: NSUnderlineStyle.single.rawValue],
                range: range
            )
        case .image(let source):
            storage.addAttribute(.notessImageSource, value: source, range: range)
        case .linkDestination, .listMarker, .syntaxMarker:
            storage.addAttribute(.foregroundColor, value: colors.syntaxMarker, range: range)
        case .wikiLink:
            storage.addAttribute(.foregroundColor, value: colors.wikiLink, range: range)
        case .tag:
            storage.addAttribute(.foregroundColor, value: colors.tag, range: range)
        case .task:
            storage.addAttributes([.foregroundColor: colors.task, .cursor: NSCursor.pointingHand], range: range)
        }
    }

    /// Visual-only spacing above and below a heading via paragraph style; the
    /// text is untouched. A setext heading takes the space below after its
    /// underline line, so the two lines stay together.
    private func applyHeadingSpacing(to range: NSRange, in storage: NSTextStorage) {
        let string = storage.string as NSString
        let spacing = style.headingSpacing
        let before = NSMutableParagraphStyle()
        before.paragraphSpacingBefore = spacing
        let line = string.lineRange(for: range)
        let underline = line.upperBound < string.length ? string.lineRange(for: NSRange(location: line.upperBound, length: 0)) : nil
        let isSetext = !string.substring(with: range).hasPrefix("#") && underline.map { Self.isSetextUnderline(string.substring(with: $0)) } == true
        if isSetext, let underline {
            let after = NSMutableParagraphStyle()
            after.paragraphSpacing = spacing
            storage.addAttribute(.paragraphStyle, value: after, range: underline)
        } else {
            before.paragraphSpacing = spacing
        }
        storage.addAttribute(.paragraphStyle, value: before, range: range)
    }

    private static func isSetextUnderline(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "=" || first == "-" else { return false }
        return trimmed.allSatisfy { $0 == first }
    }

    private func addTraits(_ traits: NSFontDescriptor.SymbolicTraits, in range: NSRange, of storage: NSTextStorage) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let current = value as? NSFont ?? style.font
            storage.addAttribute(.font, value: font(current, size: current.pointSize, traits: traits), range: subrange)
        }
    }

    private struct FontKey: Hashable {
        var font: NSFont
        var size: CGFloat
        var traits: UInt32
    }

    private func font(_ base: NSFont, size: CGFloat, traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let key = FontKey(font: base, size: size, traits: traits.rawValue)
        if let cached = fontCache[key] { return cached }
        let descriptor = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(traits))
        let result = NSFont(descriptor: descriptor, size: size) ?? NSFont(descriptor: base.fontDescriptor, size: size) ?? base
        fontCache[key] = result
        return result
    }
}
