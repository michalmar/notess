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
        var dismissals = 0
        let harness = PreviewHarness(content: content) {
            dismissals += 1
        }
        harness.window.makeKeyAndOrderFront(nil)
        harness.installOverlay()
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

        #expect(dismissals == 1)
    }

    @Test("Escape dismisses the hosted overlay and it takes focus from the editor")
    func escapeDismissalAndFocus() throws {
        let content = ImagePreviewContent(
            source: "attachments/image.png",
            image: try #require(testPreviewImage())
        )
        var dismissals = 0
        let harness = PreviewHarness(content: content) {
            dismissals += 1
        }
        harness.window.makeKeyAndOrderFront(nil)
        harness.window.makeFirstResponder(harness.textView)
        harness.installOverlay()
        runMainLoop()

        #expect(harness.window.firstResponder !== harness.textView)

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

        #expect(dismissals == 1)
    }
}

@MainActor
private final class PreviewHarness {
    let window: NSWindow
    let textView = NSTextView()
    let hostingView: NSHostingView<ImagePreviewOverlay>

    init(content: ImagePreviewContent, onDismiss: @escaping () -> Void) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        hostingView = NSHostingView(
            rootView: ImagePreviewOverlay(content: content, onDismiss: onDismiss)
        )
        installOverlay()
        runMainLoop()
    }

    func installOverlay() {
        let container = NSView(frame: window.contentLayoutRect)
        textView.frame = container.bounds
        textView.autoresizingMask = [.width, .height]
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(textView)
        container.addSubview(hostingView)
        window.contentView = container
    }

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
