import AppKit
import SwiftUI
import Testing
@testable import NotessEditor

@MainActor
@Suite("Image preview")
struct ImagePreviewTests {
    @Test("wide and tall images fit the available area without distortion or cropping")
    func aspectRatioFit() {
        let available = CGSize(width: 800, height: 600)

        let wide = ImagePreviewLayout.fittedSize(
            imageSize: CGSize(width: 1_600, height: 400),
            availableSize: available
        )
        #expect(wide == CGSize(width: 800, height: 200))

        let tall = ImagePreviewLayout.fittedSize(
            imageSize: CGSize(width: 300, height: 1_200),
            availableSize: available
        )
        #expect(tall == CGSize(width: 150, height: 600))
    }

    @Test("resizing recomputes the fit from the current available area")
    func resizing() {
        let image = CGSize(width: 1_600, height: 900)

        #expect(
            ImagePreviewLayout.fittedSize(
                imageSize: image,
                availableSize: CGSize(width: 1_200, height: 800)
            ) == CGSize(width: 1_200, height: 675)
        )
        #expect(
            ImagePreviewLayout.fittedSize(
                imageSize: image,
                availableSize: CGSize(width: 600, height: 800)
            ) == CGSize(width: 600, height: 337.5)
        )
    }

    @Test("the visible Close control dismisses the hosted overlay")
    func closeButtonDismissal() throws {
        let content = ImagePreviewContent(
            source: "attachments/image.png",
            image: try #require(testPreviewImage())
        )
        let harness = PreviewHarness(content: content)
        harness.window.makeKeyAndOrderFront(nil)
        runMainLoop()
        let closePoint = NSPoint(
            x: harness.hostingView.bounds.maxX - 58,
            y: harness.hostingView.bounds.maxY - 35
        )
        let mouseDown = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: closePoint,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: harness.window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )
        let mouseUp = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: closePoint,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: harness.window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 0
            )
        )
        harness.window.sendEvent(mouseDown)
        harness.window.sendEvent(mouseUp)
        runMainLoop()

        #expect(harness.state.isPresented == false)
        #expect(harness.state.dismissals == 1)
        #expect(harness.window.firstResponder === harness.textView)
    }

    @Test("Escape dismisses the hosted overlay and it takes focus from the editor")
    func escapeDismissalAndFocus() throws {
        let content = ImagePreviewContent(
            source: "attachments/image.png",
            image: try #require(testPreviewImage())
        )
        let harness = PreviewHarness(content: content)
        harness.window.makeKeyAndOrderFront(nil)
        runMainLoop()
        let textView = try #require(harness.textView)

        #expect(harness.window.firstResponder !== textView)

        let escape = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: harness.window.windowNumber,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            )
        )
        harness.window.sendEvent(escape)
        runMainLoop()

        #expect(harness.state.isPresented == false)
        #expect(harness.state.dismissals == 1)
        #expect(harness.window.firstResponder === textView)
    }
}

@MainActor
private final class PreviewHarness {
    let window: NSWindow
    let hostingView: NSHostingView<PreviewInteractionHarnessView>
    let state = PreviewHarnessState()
    var textView: MarkdownTextView? {
        allSubviews(of: hostingView)
            .compactMap { $0 as? MarkdownTextView }
            .first
    }

    init(content: ImagePreviewContent) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        hostingView = NSHostingView(
            rootView: PreviewInteractionHarnessView(
                content: content,
                state: state
            )
        )
        hostingView.frame = window.contentLayoutRect
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
        runMainLoop()
    }

}

@MainActor
private final class PreviewHarnessState: ObservableObject {
    @Published var isPresented = true
    private(set) var dismissals = 0

    func dismiss() {
        isPresented = false
        dismissals += 1
    }
}

@MainActor
private struct PreviewInteractionHarnessView: View {
    let content: ImagePreviewContent
    @ObservedObject var state: PreviewHarnessState

    var body: some View {
        ZStack {
            MarkdownEditor(
                documentID: "preview-test",
                initialText: { "Poznámka" },
                isInteractionEnabled: !state.isPresented,
                noteURL: URL(filePath: "/tmp/preview-test.md"),
                onTextChange: { _ in }
            )

            if state.isPresented {
                ImagePreviewOverlay(content: content) {
                    state.dismiss()
                }
            }
        }
    }
}

@MainActor
private func allSubviews(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(allSubviews)
}

@MainActor
private func runMainLoop() {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
}

private func testPreviewImage() -> NSImage? {
    let size = NSSize(width: 2, height: 1)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.red.setFill()
    NSRect(origin: .zero, size: size).fill()
    image.unlockFocus()
    return image
}
