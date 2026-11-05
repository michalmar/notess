import SwiftUI

extension View {
    /// A link-looking button: the native link style, or the palette's link
    /// role under a custom palette, where the system link blue would clash.
    func themedLinkButtonStyle() -> some View {
        modifier(ThemedLinkButtonStyle())
    }
}

private struct ThemedLinkButtonStyle: ViewModifier {
    @Environment(\.themePalette) private var palette

    func body(content: Content) -> some View {
        if let palette {
            content
                .buttonStyle(.plain)
                .foregroundStyle(Color(nsColor: palette.link))
        } else {
            content.buttonStyle(.link)
        }
    }
}
