import AppKit

/// Fonts and colours of the Markdown editor.
///
/// Built by `MarkdownEditor` from the Settings font and size; changing the
/// style restyles the whole note. The default colours
/// are dynamic system colours, so they follow the light/dark appearance; a
/// theme replaces them without touching fonts or geometry.
public struct MarkdownEditorStyle: Equatable {
    public struct Colors: Equatable {
        /// The editor's surface behind the text.
        public var background: NSColor
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
        /// The grid lines of a table.
        public var tableBorder: NSColor
        public var tableHeaderBackground: NSColor
        /// The selected-text highlight; nil keeps AppKit's native one.
        public var selection: NSColor?
        /// The caret; nil keeps AppKit's native one.
        public var insertionPoint: NSColor?

        public init(
            background: NSColor = .textBackgroundColor,
            text: NSColor = .textColor,
            syntaxMarker: NSColor = .tertiaryLabelColor,
            link: NSColor = .linkColor,
            wikiLink: NSColor = .systemPurple,
            tag: NSColor = .systemOrange,
            task: NSColor = .controlAccentColor,
            quote: NSColor = .secondaryLabelColor,
            completedTask: NSColor = .secondaryLabelColor,
            codeBackground: NSColor = .quaternarySystemFill,
            tableBorder: NSColor = .separatorColor,
            tableHeaderBackground: NSColor = .quaternarySystemFill,
            selection: NSColor? = nil,
            insertionPoint: NSColor? = nil
        ) {
            self.background = background
            self.text = text
            self.syntaxMarker = syntaxMarker
            self.link = link
            self.wikiLink = wikiLink
            self.tag = tag
            self.task = task
            self.quote = quote
            self.completedTask = completedTask
            self.codeBackground = codeBackground
            self.tableBorder = tableBorder
            self.tableHeaderBackground = tableHeaderBackground
            self.selection = selection
            self.insertionPoint = insertionPoint
        }
    }

    /// The style with the native surface colours: what the styled text depends on.
    var withoutSurfaceColors: MarkdownEditorStyle {
        var style = self
        let native = Colors()
        style.colors.background = native.background
        style.colors.selection = native.selection
        style.colors.insertionPoint = native.insertionPoint
        return style
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

    /// Extra space above and below every heading: half a body-text line, so it
    /// follows the editor font size and text zoom, not the heading's own size.
    public var headingSpacing: CGFloat {
        ((font.ascender - font.descender + font.leading) / 2).rounded(.up)
    }

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
