import AppKit

/// Fonts and colours of the Markdown editor.
///
/// Injected into `MarkdownEditor` so that Settings (font, size, theme) can
/// change it; changing the style restyles the whole note. The default colours
/// are dynamic system colours, so they follow the light/dark appearance.
public struct MarkdownEditorStyle: Equatable {
    public struct Colors: Equatable {
        public var text: NSColor
        /// Markdown markup characters: visible but dimmed.
        public var syntaxMarker: NSColor
        public var link: NSColor
        public var wikiLink: NSColor
        public var tag: NSColor
        public var task: NSColor
        public var quote: NSColor
        public var completedTask: NSColor
        public var codeBackground: NSColor

        public init(
            text: NSColor = .textColor,
            syntaxMarker: NSColor = .tertiaryLabelColor,
            link: NSColor = .linkColor,
            wikiLink: NSColor = .systemPurple,
            tag: NSColor = .systemOrange,
            task: NSColor = .controlAccentColor,
            quote: NSColor = .secondaryLabelColor,
            completedTask: NSColor = .secondaryLabelColor,
            codeBackground: NSColor = .quaternarySystemFill
        ) {
            self.text = text
            self.syntaxMarker = syntaxMarker
            self.link = link
            self.wikiLink = wikiLink
            self.tag = tag
            self.task = task
            self.quote = quote
            self.completedTask = completedTask
            self.codeBackground = codeBackground
        }
    }

    /// The body font; headings and code are derived from its size.
    public var font: NSFont
    public var codeFont: NSFont
    public var colors: Colors

    public init(font: NSFont? = nil, codeFont: NSFont? = nil, colors: Colors = Colors()) {
        let font = font ?? .systemFont(ofSize: 15)
        self.font = font
        self.codeFont = codeFont ?? .monospacedSystemFont(ofSize: (font.pointSize * 0.93).rounded(), weight: .regular)
        self.colors = colors
    }

    /// A style with the body font from Settings: a PostScript font name, or
    /// `"System"` (also used when the font is not installed).
    public init(fontName: String, fontSize: CGFloat, colors: Colors = Colors()) {
        let custom = fontName == "System" ? nil : NSFont(name: fontName, size: fontSize)
        self.init(font: custom ?? .systemFont(ofSize: fontSize), colors: colors)
    }

    public static var standard: MarkdownEditorStyle { MarkdownEditorStyle() }

    /// Heading size relative to the body font, by level.
    static func headingScale(_ level: Int) -> CGFloat {
        switch level {
        case 1: 1.6
        case 2: 1.35
        case 3: 1.15
        default: 1.0
        }
    }
}
