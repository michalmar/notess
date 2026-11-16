import AppKit
import NotessCore
import Observation
import SwiftUI

/// What the shared in-window preview shows: the note's Image Gallery opened
/// at the clicked occurrence.
///
/// Editable notes and read-only views such as Tag Timeline Sections can both
/// create this value and present it through `ImagePreviewPresentation`.
public struct ImagePreviewContent: Identifiable {
    public let id: UUID
    /// Every image occurrence the preview can browse, in document order.
    public let gallery: ImageGallery
    /// The occurrence the preview opens at.
    public let startIndex: Int
    /// The source of the opening occurrence.
    public let source: String
    /// The image of the opening occurrence.
    public let image: NSImage
    private let loadImage: (ImageGallery.Occurrence) -> NSImage?

    /// A preview of one image without other occurrences to browse.
    public init(id: UUID = UUID(), source: String, image: NSImage) {
        self.init(
            id: id,
            gallery: ImageGallery(occurrences: [
                ImageGallery.Occurrence(source: source, range: NSRange(location: 0, length: 0)),
            ]),
            startIndex: 0,
            image: image,
            loadImage: { _ in nil }
        )
    }

    /// A preview of `gallery` opened at `startIndex`, whose `image` is already
    /// loaded. `loadImage` loads any other occurrence when it is shown and
    /// returns nil when it cannot.
    public init(
        id: UUID = UUID(),
        gallery: ImageGallery,
        startIndex: Int,
        image: NSImage,
        loadImage: @escaping (ImageGallery.Occurrence) -> NSImage?
    ) {
        precondition(gallery.occurrences.indices.contains(startIndex))
        self.id = id
        self.gallery = gallery
        self.startIndex = startIndex
        self.source = gallery.occurrences[startIndex].source
        self.image = image
        self.loadImage = loadImage
    }

    /// The image of the occurrence at `index`, or nil when it cannot be loaded.
    public func image(at index: Int) -> NSImage? {
        guard gallery.occurrences.indices.contains(index) else { return nil }
        return index == startIndex ? image : loadImage(gallery.occurrences[index])
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
///
/// It browses the content's Image Gallery: Left/Right Arrow and the previous
/// and next buttons move one occurrence at a time and stop at the ends. A
/// descriptive breadcrumb above the image names the occurrence's headings.
public struct ImagePreviewOverlay: View {
    private let content: ImagePreviewContent
    private let onDismiss: () -> Void
    @State private var browsed: (contentID: UUID, index: Int)?
    @FocusState private var isCloseButtonFocused: Bool

    public init(content: ImagePreviewContent, onDismiss: @escaping () -> Void) {
        self.content = content
        self.onDismiss = onDismiss
    }

    private var index: Int {
        guard let browsed, browsed.contentID == content.id else { return content.startIndex }
        return browsed.index
    }

    /// Keeps the breadcrumb clear of the Close button in the top corner.
    private static let breadcrumbInset: CGFloat = 140
    private static let breadcrumbHeight: CGFloat = 18

    private var canShowPrevious: Bool { index > 0 }
    private var canShowNext: Bool { index < content.gallery.occurrences.count - 1 }

    private func show(_ newIndex: Int) {
        guard content.gallery.occurrences.indices.contains(newIndex) else { return }
        browsed = (content.id, newIndex)
    }

    public var body: some View {
        let image = content.image(at: index)
        let headings = content.gallery.occurrences[index].headings
        GeometryReader { geometry in
            let availableSize = CGSize(
                width: max(0, geometry.size.width - 64),
                height: max(0, geometry.size.height - 96)
            )
            let fittedSize = ImagePreviewLayout.fittedSize(
                imageSize: image?.size ?? .zero,
                availableSize: availableSize
            )

            ZStack(alignment: .topTrailing) {
                Color.black.opacity(0.82)
                    .ignoresSafeArea()

                PreviewImageView(image: image)
                    .frame(width: fittedSize.width, height: fittedSize.height)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)

                if !headings.isEmpty {
                    let imageTop = (geometry.size.height - fittedSize.height) / 2
                    HeadingBreadcrumb(text: headings.joined(separator: " → "))
                        .frame(
                            width: max(0, geometry.size.width - 2 * Self.breadcrumbInset),
                            height: Self.breadcrumbHeight
                        )
                        .position(
                            x: geometry.size.width / 2,
                            y: max(Self.breadcrumbHeight / 2, imageTop - 6 - Self.breadcrumbHeight / 2)
                        )
                }

                HStack {
                    GalleryButton(
                        direction: .previous,
                        isEnabled: canShowPrevious,
                        action: { show(index - 1) }
                    )
                    Spacer()
                    GalleryButton(
                        direction: .next,
                        isEnabled: canShowNext,
                        action: { show(index + 1) }
                    )
                }
                .padding(.horizontal, 12)
                .frame(maxHeight: .infinity)

                Button("Zavřít", systemImage: "xmark") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.cancelAction)
                .focused($isCloseButtonFocused)
                .padding(20)
            }
        }
        .onExitCommand(perform: onDismiss)
        .onAppear {
            isCloseButtonFocused = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Zvětšený náhled obrázku")
    }
}

/// The enlarged image, drawn by AppKit to fill the frame the overlay fits it in.
private struct PreviewImageView: NSViewRepresentable {
    let image: NSImage?

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleAxesIndependently
        view.setAccessibilityLabel("Náhled obrázku")
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        view.image = image
    }
}

/// The current occurrence's headings, outermost first, as small plain text.
/// It describes where the image is and does nothing when clicked.
private struct HeadingBreadcrumb: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = NSColor.white.withAlphaComponent(0.75)
        field.alignment = .center
        field.lineBreakMode = .byTruncatingHead
        field.isSelectable = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("Nadpisy obrázku")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.stringValue = text
    }
}

/// A previous or next button of the gallery, also triggered by its arrow key.
private struct GalleryButton: NSViewRepresentable {
    enum Direction {
        case previous, next
    }

    let direction: Direction
    let isEnabled: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> GalleryNavigationButton {
        let label = direction == .previous ? "Předchozí obrázek" : "Další obrázek"
        let symbol = direction == .previous ? "chevron.left" : "chevron.right"
        let button = GalleryNavigationButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
            target: nil,
            action: nil
        )
        button.bezelStyle = .circular
        button.controlSize = .large
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.arrowKey = direction == .previous ? NSLeftArrowFunctionKey : NSRightArrowFunctionKey
        return button
    }

    func updateNSView(_ button: GalleryNavigationButton, context: Context) {
        button.onActivate = action
        button.isEnabled = isEnabled
    }
}

/// Activates on a click or its arrow key without NSButtonCell's click
/// tracking and highlight animation, which spins nested run loops and stops
/// the main one from a background animation.
final class GalleryNavigationButton: NSButton {
    var onActivate: (() -> Void)?
    var arrowKey: Int = 0

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onActivate?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        guard event.type == .keyDown, modifiers.isEmpty,
              event.charactersIgnoringModifiers?.unicodeScalars.first?.value == UInt32(arrowKey) else {
            return false
        }
        if isEnabled { onActivate?() }
        return true
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onActivate?()
        return true
    }
}
