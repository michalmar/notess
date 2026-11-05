import AppKit
import NotessCore
import NotessEditor
import SwiftUI
import Synchronization

/// The colours of a custom theme by semantic role. Native themes have none
/// and keep AppKit's dynamic system colours and the system accent.
///
/// The single source of custom colours for every app-owned surface: SwiftUI
/// views read the current palette from `\.themePalette` (or use
/// `themedBackground`/`themedForeground`), Markdown views take
/// `AppTheme.markdownColors`.
struct ThemePalette: Equatable, @unchecked Sendable {
    /// The writing surface: editors and read-only Markdown.
    let background: NSColor
    /// Shell chrome around it: sidebar, tab bar, bars, Settings.
    let surface: NSColor
    let text: NSColor
    let secondaryText: NSColor
    let separator: NSColor
    /// The brand accent for control tint and highlights.
    let accent: NSColor
    /// The accent where it must stand out against the background on its own,
    /// such as the caret and Task checkboxes.
    let strongAccent: NSColor
    let selection: NSColor
    let link: NSColor
    let wikiLink: NSColor
    let tag: NSColor
    let quote: NSColor
    let completedTask: NSColor
    let syntaxMarker: NSColor
    let codeBackground: NSColor
    let tableBorder: NSColor
    let tableHeaderBackground: NSColor
    let error: NSColor
    let warning: NSColor
    let success: NSColor

    /// Always light. Adapted from the Noir Essence Light reference palette
    /// (cream `#f7f3ea`, black text, orange `#e78a4e`; supporting red, pink,
    /// orange, yellow and blue), darkened where text needs to stay readable:
    /// readability and status meaning win over literal reference values.
    /// Increased contrast uses darker variants of every text role.
    static let noirEssence = ThemePalette(
        background: color(0xF7F3EA),
        surface: color(0xEFE8DA),
        text: color(0x1C1813, increased: 0x000000),
        secondaryText: color(0x5E564B, increased: 0x2F2A24),
        separator: color(0xD9CFBD, increased: 0x8A7D66),
        accent: color(0xE78A4E, increased: 0xB35A1E),
        strongAccent: color(0xC4672A, increased: 0x8F420E),
        selection: color(0xE78A4E, alpha: 0.3),
        link: color(0x3A6D93, increased: 0x1D4A6E),
        wikiLink: color(0x9C4562, increased: 0x6E2340),
        tag: color(0xA2531F, increased: 0x6F3208),
        quote: color(0x5E564B, increased: 0x2F2A24),
        completedTask: color(0x6B6357, increased: 0x3A342C),
        syntaxMarker: color(0xA0968A, increased: 0x5D554B),
        codeBackground: color(0xEBE3D3, increased: 0xE0D4BD),
        tableBorder: color(0xCFC4B0, increased: 0x8A7D66),
        tableHeaderBackground: color(0xEFE7D8, increased: 0xE6DCC8),
        error: color(0xB8423C, increased: 0x8E2A25),
        warning: color(0xA87612, increased: 0x7D5600),
        success: color(0x3D7A3A, increased: 0x275A25)
    )

    private static func color(_ hex: UInt32, increased: UInt32? = nil, alpha: CGFloat = 1) -> NSColor {
        let normal = srgb(hex, alpha: alpha)
        guard let increased else { return normal }
        let high = srgb(increased, alpha: alpha)
        return NSColor(name: nil) { appearance in
            increasedContrast(in: appearance) ? high : normal
        }
    }

    private static let contrastOverride = Mutex<Bool?>(nil)

    /// Replaces the system's Increase Contrast setting; tests cannot switch
    /// it, nor create a high-contrast appearance. nil follows the system.
    static var increasedContrastOverride: Bool? {
        get { contrastOverride.withLock { $0 } }
        set { contrastOverride.withLock { $0 = newValue } }
    }

    private static func increasedContrast(in appearance: NSAppearance) -> Bool {
        if let increased = increasedContrastOverride { return increased }
        return appearance.bestMatch(from: [.aqua, .accessibilityHighContrastAqua]) == .accessibilityHighContrastAqua
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    private static func srgb(_ hex: UInt32, alpha: CGFloat) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension AppTheme {
    /// The custom palette; nil for native themes.
    var palette: ThemePalette? {
        switch self {
        case .system, .light, .dark: nil
        case .noirEssence: .noirEssence
        }
    }

    /// Formatting colours for editable and read-only Markdown views.
    ///
    /// The text colours are the same theme-following instances for every
    /// theme, so a theme switch leaves the style of the text unchanged and
    /// needs only a redraw: restyling would invalidate TextKit 2 layout and
    /// move the reading position. Only the surface colours differ per theme.
    @MainActor var markdownColors: MarkdownEditorStyle.Colors {
        var colors = ThemePalette.followingColors
        if let palette {
            colors.background = palette.background
            colors.selection = palette.selection
            colors.insertionPoint = palette.strongAccent
        }
        return colors
    }
}

extension ThemePalette {
    private static let active = Mutex<ThemePalette?>(nil)

    /// The palette theme-following colours resolve to; nil for native themes.
    /// Set by `ApplicationTheme`, which then redraws every window.
    static var current: ThemePalette? {
        get { active.withLock { $0 } }
        set { active.withLock { $0 = newValue } }
    }

    /// Markdown text colours that resolve to the current palette's roles, or
    /// to the native colours without one. Surface colours stay native here.
    @MainActor static let followingColors: MarkdownEditorStyle.Colors = {
        let native = MarkdownEditorStyle.Colors()
        return MarkdownEditorStyle.Colors(
            text: following({ $0.text }, native: native.text),
            syntaxMarker: following({ $0.syntaxMarker }, native: native.syntaxMarker),
            link: following({ $0.link }, native: native.link),
            wikiLink: following({ $0.wikiLink }, native: native.wikiLink),
            tag: following({ $0.tag }, native: native.tag),
            task: following({ $0.strongAccent }, native: native.task),
            quote: following({ $0.quote }, native: native.quote),
            completedTask: following({ $0.completedTask }, native: native.completedTask),
            codeBackground: following({ $0.codeBackground }, native: native.codeBackground),
            tableBorder: following({ $0.tableBorder }, native: native.tableBorder),
            tableHeaderBackground: following({ $0.tableHeaderBackground }, native: native.tableHeaderBackground)
        )
    }()

    // Nonisolated with a `@Sendable` provider: AppKit may resolve colours off
    // the main thread.
    private nonisolated static func following(
        _ role: @escaping @Sendable (ThemePalette) -> NSColor,
        native: NSColor
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let color = current.map(role) ?? native
            var resolved = color
            appearance.performAsCurrentDrawingAppearance {
                resolved = color.usingColorSpace(.extendedSRGB) ?? color
            }
            return resolved
        }
    }
}

extension EnvironmentValues {
    /// The current custom palette, set application-wide by `ApplicationTheme`;
    /// nil while a native theme is selected.
    @Entry var themePalette: ThemePalette?
}

extension View {
    /// Fills behind the view with a palette role, or `native` without a custom palette.
    func themedBackground<S: ShapeStyle>(_ role: KeyPath<ThemePalette, NSColor>, native: S) -> some View {
        modifier(ThemedBackground(role: role, native: AnyShapeStyle(native)))
    }

    /// Colours the view's content with a palette role, or `native` without a custom palette.
    func themedForeground<S: ShapeStyle>(_ role: KeyPath<ThemePalette, NSColor>, native: S) -> some View {
        modifier(ThemedForeground(role: role, native: AnyShapeStyle(native)))
    }
}

private struct ThemedBackground: ViewModifier {
    let role: KeyPath<ThemePalette, NSColor>
    let native: AnyShapeStyle
    @Environment(\.themePalette) private var palette

    func body(content: Content) -> some View {
        content.background(palette.map { AnyShapeStyle(Color(nsColor: $0[keyPath: role])) } ?? native)
    }
}

private struct ThemedForeground: ViewModifier {
    let role: KeyPath<ThemePalette, NSColor>
    let native: AnyShapeStyle
    @Environment(\.themePalette) private var palette

    func body(content: Content) -> some View {
        content.foregroundStyle(palette.map { AnyShapeStyle(Color(nsColor: $0[keyPath: role])) } ?? native)
    }
}
