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
/// visible and is only dimmed; nothing is hidden.
@MainActor
final class MarkdownHighlighter: NSObject, NSTextStorageDelegate {
    let lexer = MarkdownLexer()
    private(set) var style: MarkdownEditorStyle
    private var fontCache: [FontKey: NSFont] = [:]
    var didStyleText: (NSRange, NSRange?, Int) -> Void = { _, _, _ in }

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
        let tokens = lexer.reset(text: storage.mutableString)
        storage.beginEditing()
        apply(tokens, in: NSRange(location: 0, length: storage.length), to: storage)
        storage.endEditing()
        didStyleText(NSRange(location: 0, length: storage.length), nil, 0)
    }

    /// Attributes of unformatted text; also the editor's typing attributes.
    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: style.font, .foregroundColor: style.colors.text]
    }

    nonisolated func textStorage(
        _ textStorage: NSTextStorage,
        willProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        // The editor's text storage is only ever edited on the main thread.
        nonisolated(unsafe) let storage = textStorage
        MainActor.assumeIsolated {
            let update = lexer.update(text: storage.mutableString, editedRange: editedRange, changeInLength: delta)
            apply(update.tokens, in: update.range, to: storage)
            didStyleText(update.range, editedRange, delta)
        }
    }

    // MARK: Applying tokens

    private func apply(_ tokens: [MarkdownToken], in range: NSRange, to storage: NSTextStorage) {
        guard range.length > 0 else { return }
        storage.setAttributes(baseAttributes, range: range)
        for layer in 0..<3 {
            for token in tokens where Self.layer(of: token.kind) == layer {
                apply(token, to: storage)
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
