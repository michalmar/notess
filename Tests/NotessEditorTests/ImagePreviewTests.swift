import AppKit
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

    @Test("Close and Escape use the same dismissal state")
    func dismissal() throws {
        let presentation = ImagePreviewPresentation()
        let content = ImagePreviewContent(
            source: "attachments/image.png",
            image: try #require(testPreviewImage())
        )

        presentation.present(content)
        #expect(presentation.content?.source == "attachments/image.png")

        presentation.dismiss()
        #expect(presentation.content == nil)

        presentation.present(content)
        presentation.dismiss()
        #expect(presentation.content == nil)
    }
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
