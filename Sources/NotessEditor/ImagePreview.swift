import AppKit
import Observation
import SwiftUI

/// A loaded image ready for the shared in-window preview.
///
/// Editable notes and read-only views such as Tag Timeline Sections can both
/// create this value and present it through `ImagePreviewPresentation`.
public struct ImagePreviewContent: Identifiable {
    public let id: UUID
    public let source: String
    public let image: NSImage

    public init(id: UUID = UUID(), source: String, image: NSImage) {
        self.id = id
        self.source = source
        self.image = image
    }
}

/// Shared presentation state for the current window's image preview.
@MainActor
@Observable
public final class ImagePreviewPresentation {
    public private(set) var content: ImagePreviewContent?

    public init() {}

    public func present(_ content: ImagePreviewContent) {
        self.content = content
    }

    public func dismiss() {
        content = nil
    }
}

/// Aspect-ratio-preserving layout used by the shared preview.
public enum ImagePreviewLayout {
    public static func fittedSize(imageSize: CGSize, availableSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              availableSize.width > 0, availableSize.height > 0 else {
            return .zero
        }
        let scale = min(
            availableSize.width / imageSize.width,
            availableSize.height / imageSize.height
        )
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}

/// A reusable image preview overlay that stays inside the current window.
public struct ImagePreviewOverlay: View {
    private let content: ImagePreviewContent
    private let onDismiss: () -> Void

    public init(content: ImagePreviewContent, onDismiss: @escaping () -> Void) {
        self.content = content
        self.onDismiss = onDismiss
    }

    public var body: some View {
        GeometryReader { geometry in
            let availableSize = CGSize(
                width: max(0, geometry.size.width - 64),
                height: max(0, geometry.size.height - 96)
            )
            let fittedSize = ImagePreviewLayout.fittedSize(
                imageSize: content.image.size,
                availableSize: availableSize
            )

            ZStack(alignment: .topTrailing) {
                Color.black.opacity(0.82)
                    .ignoresSafeArea()

                Image(nsImage: content.image)
                    .resizable()
                    .frame(width: fittedSize.width, height: fittedSize.height)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .accessibilityLabel("Náhled obrázku")

                Button("Zavřít", systemImage: "xmark") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.cancelAction)
                .padding(20)
            }
        }
        .onExitCommand(perform: onDismiss)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Zvětšený náhled obrázku")
    }
}
