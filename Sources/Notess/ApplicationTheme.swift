import AppKit
import NotessCore
import SwiftUI

extension AppTheme {
    var title: String {
        switch self {
        case .system: "Podle systému"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var nativeAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Set the application override, not a view's color scheme: AppKit editors,
/// other windows and native dialogs must inherit the same appearance.
struct ApplicationTheme: ViewModifier {
    let theme: AppTheme

    func body(content: Content) -> some View {
        content.onChange(of: theme, initial: true) {
            NSApp.appearance = theme.nativeAppearance
        }
    }
}
