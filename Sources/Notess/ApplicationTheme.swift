import AppKit
import NotessCore
import SwiftUI

extension AppTheme {
    var title: String {
        switch self {
        case .system: "Podle systému"
        case .light: "Light"
        case .dark: "Dark"
        case .noirEssence: "Noir Essence"
        }
    }

    var nativeAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light, .noirEssence: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor private func redraw(_ view: NSView) {
    view.needsDisplay = true
    view.subviews.forEach(redraw)
}

/// Set the application override, not a view's color scheme: AppKit editors,
/// other windows and native dialogs must inherit the same appearance. A custom
/// palette reaches SwiftUI content through the environment and control tint;
/// native dialogs only get the native appearance, never custom colours.
struct ApplicationTheme: ViewModifier {
    let theme: AppTheme

    func body(content: Content) -> some View {
        content
            .environment(\.themePalette, theme.palette)
            .tint(theme.palette.map { Color(nsColor: $0.accent) })
            .onChange(of: theme, initial: true) {
                let palette = theme.palette
                let paletteChanged = ThemePalette.current != palette
                ThemePalette.current = palette
                NSApp.appearance = theme.nativeAppearance
                // Theme-following colours re-resolve on redraw; an appearance
                // change redraws by itself, a palette change on the same
                // appearance (Light and Noir Essence) does not.
                if paletteChanged {
                    for window in NSApp.windows {
                        window.contentView.map(redraw)
                    }
                }
            }
    }
}
