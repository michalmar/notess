import AppKit
import NotessCore
import SwiftUI
import Testing
@testable import NotessEditor

/// The Image Gallery, exercised only through the enlarged preview: clicking an
/// inline image in a real editor, then arrow keys and the visible buttons
/// (issues #155 and #156).
@MainActor
@Suite("Image Gallery")
struct ImageGalleryTests {
    @Test("clicking a middle image opens it and Right Arrow shows the next occurrence")
    func openMiddleAndBrowseRight() async throws {
        let harness = try GalleryHarness(note: """
        ![](attachments/red.png)

        ![](attachments/green.png)

        ![](attachments/blue.png)
        """)

        try harness.clickImage("![](attachments/green.png)")
        #expect(harness.displayedImage() == "green")

        harness.press(.right)
        #expect(harness.displayedImage() == "blue")
    }

    @Test("Left Arrow and the previous and next buttons browse the same occurrences as the keys")
    func keysAndButtonsBrowseAlike() async throws {
        let harness = try GalleryHarness(note: """
        ![](attachments/red.png)

        ![](attachments/green.png)

        ![](attachments/blue.png)

        ![](attachments/yellow.png)
        """)

        try harness.clickImage("![](attachments/blue.png)")
        #expect(harness.displayedImage() == "blue")
        harness.press(.left)
        #expect(harness.displayedImage() == "green")
        harness.press(.left)
        #expect(harness.displayedImage() == "red")

        try harness.clickButton(GalleryHarness.next)
        #expect(harness.displayedImage() == "green")
        try harness.clickButton(GalleryHarness.next)
        #expect(harness.displayedImage() == "blue")
        try harness.clickButton(GalleryHarness.next)
        #expect(harness.displayedImage() == "yellow")
        try harness.clickButton(GalleryHarness.previous)
        #expect(harness.displayedImage() == "blue")
    }

    @Test("browsing stops at the first and last occurrence with that direction disabled")
    func boundariesDoNotWrap() async throws {
        let harness = try GalleryHarness(note: """
        ![](attachments/red.png)

        ![](attachments/green.png)

        ![](attachments/blue.png)
        """)

        try harness.clickImage("![](attachments/red.png)")
        #expect(try harness.button(GalleryHarness.previous).isEnabled == false)
        #expect(try harness.button(GalleryHarness.next).isEnabled)
        harness.press(.left)
        harness.press(.left)
        try harness.clickButton(GalleryHarness.previous)
        #expect(harness.displayedImage() == "red")

        harness.press(.right)
        #expect(try harness.button(GalleryHarness.previous).isEnabled)
        #expect(try harness.button(GalleryHarness.next).isEnabled)
        harness.press(.right)
        #expect(harness.displayedImage() == "blue")
        #expect(try harness.button(GalleryHarness.next).isEnabled == false)
        #expect(try harness.button(GalleryHarness.previous).isEnabled)
        harness.press(.right)
        harness.press(.right)
        try harness.clickButton(GalleryHarness.next)
        #expect(harness.displayedImage() == "blue")
    }

    @Test("a note with one image disables both directions")
    func singleImage() async throws {
        let harness = try GalleryHarness(note: """
        Just one picture:

        ![](attachments/cyan.png)
        """)

        try harness.clickImage("![](attachments/cyan.png)")
        #expect(try harness.button(GalleryHarness.previous).isEnabled == false)
        #expect(try harness.button(GalleryHarness.next).isEnabled == false)
        harness.press(.right)
        harness.press(.left)
        try harness.clickButton(GalleryHarness.next)
        try harness.clickButton(GalleryHarness.previous)
        #expect(harness.displayedImage() == "cyan")
    }

    @Test("each insertion of a repeated image is its own occurrence")
    func repeatedSourcesStayDistinct() async throws {
        let harness = try GalleryHarness(note: """
        ![](attachments/red.png)

        ![](attachments/green.png)

        ![](attachments/red.png)

        ![](attachments/blue.png)
        """)

        try harness.clickImage("![](attachments/red.png)", occurrence: 1)
        #expect(harness.displayedImage() == "red")
        #expect(try harness.button(GalleryHarness.previous).isEnabled)
        harness.press(.left)
        #expect(harness.displayedImage() == "green")
        harness.press(.left)
        #expect(harness.displayedImage() == "red")
        #expect(try harness.button(GalleryHarness.previous).isEnabled == false)
        harness.press(.right)
        harness.press(.right)
        #expect(harness.displayedImage() == "red")
        harness.press(.right)
        #expect(harness.displayedImage() == "blue")
    }

    @Test("browsing crosses headings and includes images before the first heading")
    func browsingCrossesHeadings() async throws {
        let harness = try GalleryHarness(note: """
        ![](attachments/yellow.png)

        # Trip

        ![](attachments/red.png)

        ## Day one

        ![](attachments/green.png)

        Results
        =======

        ![](attachments/blue.png)
        """)

        try harness.clickImage("![](attachments/red.png)")
        harness.press(.left)
        #expect(harness.displayedImage() == "yellow")
        harness.press(.right)
        harness.press(.right)
        #expect(harness.displayedImage() == "green")
        harness.press(.right)
        #expect(harness.displayedImage() == "blue")
        #expect(try harness.button(GalleryHarness.next).isEnabled == false)
    }

    @Test("the breadcrumb shows the occurrence's heading ancestry and follows browsing")
    func breadcrumbFollowsHeadingAncestry() async throws {
        let harness = try GalleryHarness(note: """
        # Project

        ### Detail

        ![](attachments/red.png)

        ## Results

        ![](attachments/green.png)

        # Appendix

        ![](attachments/blue.png)
        """)

        try harness.clickImage("![](attachments/green.png)")
        #expect(harness.breadcrumb() == "Project → Results")
        harness.press(.left)
        #expect(harness.displayedImage() == "red")
        #expect(harness.breadcrumb() == "Project → Detail")
        try harness.clickButton(GalleryHarness.next)
        try harness.clickButton(GalleryHarness.next)
        #expect(harness.displayedImage() == "blue")
        #expect(harness.breadcrumb() == "Appendix")
        try harness.clickButton(GalleryHarness.previous)
        #expect(harness.breadcrumb() == "Project → Results")
        harness.press(.right)
        #expect(harness.breadcrumb() == "Appendix")
    }

    @Test("the breadcrumb is small, above the image and stays there when the window resizes")
    func breadcrumbSitsAboveImage() async throws {
        let harness = try GalleryHarness(note: """
        # Project

        ![](attachments/yellow.png)
        """)

        try harness.clickImage("![](attachments/yellow.png)")
        #expect(harness.breadcrumb() == "Project")
        #expect(try harness.breadcrumbFontSize() < NSFont.systemFontSize)
        #expect(try harness.breadcrumbIsAboveImage())

        harness.window.setContentSize(NSSize(width: 500, height: 320))
        harness.settle()
        #expect(harness.displayedImage() == "yellow")
        #expect(harness.breadcrumb() == "Project")
        #expect(try harness.breadcrumbIsAboveImage())
    }

    @Test("clicking the breadcrumb changes nothing and Escape still returns focus to the note")
    func breadcrumbIsNotInteractive() async throws {
        let harness = try GalleryHarness(note: """
        # Project

        ![](attachments/red.png)

        ## Results

        ![](attachments/green.png)
        """)
        let textView = try harness.textView
        let original = textView.string

        try harness.clickImage("![](attachments/green.png)")
        try harness.clickBreadcrumb()
        #expect(harness.state.content != nil)
        #expect(harness.displayedImage() == "green")
        #expect(harness.breadcrumb() == "Project → Results")

        harness.pressEscape()
        await flushMainQueue()
        harness.settle()
        #expect(harness.state.content == nil)
        #expect(harness.breadcrumb() == nil)
        #expect(harness.window.firstResponder === textView)
        #expect(textView.string == original)
        #expect(harness.textChanges == 0)
        #expect(harness.savedText == nil)
    }

    @Test("missing heading levels are not invented and text outside headings shows no breadcrumb")
    func breadcrumbInventsNothing() async throws {
        let harness = try GalleryHarness(note: """
        ![](attachments/yellow.png)

        ## Only H2

        ![](attachments/red.png)

        ```
        # Fenced
        Fenced setext
        =============
        ```

            # Indented

        Inline `# code` and #notaheading text.

        ![](attachments/green.png)
        """)

        try harness.clickImage("![](attachments/red.png)")
        #expect(harness.breadcrumb() == "Only H2")
        harness.press(.left)
        #expect(harness.displayedImage() == "yellow")
        #expect(harness.breadcrumb() == nil)
        try harness.clickButton(GalleryHarness.next)
        try harness.clickButton(GalleryHarness.next)
        #expect(harness.displayedImage() == "green")
        #expect(harness.breadcrumb() == "Only H2")
    }

    @Test("setext headings nest and end like ATX headings")
    func setextHeadingsInBreadcrumb() async throws {
        let harness = try GalleryHarness(note: """
        Trip
        ====

        Day one
        -------

        ![](attachments/red.png)

        ### Morning

        ![](attachments/green.png)

        Day two
        -------

        ![](attachments/blue.png)
        """)

        try harness.clickImage("![](attachments/red.png)")
        #expect(harness.breadcrumb() == "Trip → Day one")
        harness.press(.right)
        #expect(harness.breadcrumb() == "Trip → Day one → Morning")
        harness.press(.right)
        #expect(harness.breadcrumb() == "Trip → Day two")
    }

    @Test("repeated sources under different headings keep their own breadcrumbs")
    func repeatedSourcesKeepTheirBreadcrumbs() async throws {
        let harness = try GalleryHarness(note: """
        # Before

        ![](attachments/red.png)

        # After

        ## Inner

        ![](attachments/red.png)
        """)

        try harness.clickImage("![](attachments/red.png)", occurrence: 1)
        #expect(harness.breadcrumb() == "After → Inner")
        harness.press(.left)
        #expect(harness.displayedImage() == "red")
        #expect(harness.breadcrumb() == "Before")
        try harness.clickButton(GalleryHarness.next)
        #expect(harness.breadcrumb() == "After → Inner")
    }

    @Test("Tag Timeline images retain ancestors outside the displayed Section")
    func timelineBreadcrumbsIncludeNoteAncestors() async throws {
        let harness = try GalleryHarness(note: """
        # Earlier

        ## Not the parent

        # Project

        ### Detail

        ![](attachments/red.png)

        ## Results
        #gallery

        ![](attachments/red.png)

        #### Close-up

        ![](attachments/missing.png)

        ![](attachments/green.png)
        """, notePath: "Journal/2026/11/2026-11-16.md")
        try await harness.showTimeline(for: "gallery")

        try harness.clickImage("![](attachments/red.png)")
        #expect(harness.breadcrumb() == "Project → Results")
        harness.press(.right)
        #expect(harness.errorFrame() != nil)
        #expect(harness.breadcrumb() == "Project → Results → Close-up")
        try harness.clickButton(GalleryHarness.next)
        #expect(harness.displayedImage() == "green")
        #expect(harness.breadcrumb() == "Project → Results → Close-up")
        try harness.clickButton(GalleryHarness.previous)
        harness.press(.left)
        #expect(harness.breadcrumb() == "Project → Results")
        harness.pressEscape()
        await flushMainQueue()
        #expect(harness.savedText == harness.note)
        #expect(harness.textChanges == 0)
    }

    @Test("Tag Timeline setext ancestors survive reopening the saved index")
    func timelineSetextAncestorsFromCachedNote() async throws {
        let harness = try GalleryHarness(note: """
        Project
        =======

        Results
        -------

        ### Detail
        #gallery

        ![](attachments/blue.png)

        End of the Section.
        """, notePath: "Journal/2026/11/2026-11-16.md")
        try await harness.showTimeline(for: "gallery")

        try harness.clickImage("![](attachments/blue.png)")
        #expect(harness.breadcrumb() == "Project → Results → Detail")
        #expect(try harness.button(GalleryHarness.previous).isEnabled == false)
        #expect(try harness.button(GalleryHarness.next).isEnabled == false)
    }

    @Test("folded, offscreen and unsaved images keep their heading context")
    func foldedOffscreenAndUnsavedBreadcrumbs() async throws {
        let filler = (1...60).map { "Line \($0) of a long note." }.joined(separator: "\n\n")
        let harness = try GalleryHarness(
            note: """
            ![](attachments/red.png)

            ## Folded

            ![](attachments/green.png)

            # Later

            \(filler)

            ![](attachments/blue.png)
            """,
            staged: ["attachments/pasted.png": "cyan"],
            height: 400
        )
        let textView = try harness.textView
        try harness.foldHeading("## Folded")
        #expect(textView.visibleInlineImageFrames.map(\.range).count == 1)
        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
        textView.insertText("\n\n## Typed\n\n![](attachments/pasted.png)", replacementRange: NSRange(location: end, length: 0))
        harness.settle()

        try harness.clickImage("![](attachments/red.png)")
        #expect(harness.breadcrumb() == nil)
        harness.press(.right)
        #expect(harness.displayedImage() == "green")
        #expect(harness.breadcrumb() == "Folded")
        harness.press(.right)
        #expect(harness.displayedImage() == "blue")
        #expect(harness.breadcrumb() == "Later")
        harness.press(.right)
        #expect(harness.displayedImage() == "cyan")
        #expect(harness.breadcrumb() == "Later → Typed")
        #expect(harness.savedText == nil)
    }

    @Test("image-like text in code is not part of the gallery")
    func codeIsNotAnImage() async throws {
        let harness = try GalleryHarness(note: """
        ![](attachments/red.png)

        ```
        ![](attachments/magenta.png)
        ```

        ![](attachments/green.png)

        Inline `![](attachments/cyan.png)` code.

            ![](attachments/yellow.png)

        ![](attachments/blue.png)
        """)

        try harness.clickImage("![](attachments/red.png)")
        harness.press(.right)
        #expect(harness.displayedImage() == "green")
        harness.press(.right)
        #expect(harness.displayedImage() == "blue")
        #expect(try harness.button(GalleryHarness.next).isEnabled == false)
    }

    @Test("folded and offscreen images stay reachable")
    func foldedAndOffscreenImages() async throws {
        let filler = (1...60).map { "Line \($0) of a long note." }.joined(separator: "\n\n")
        let harness = try GalleryHarness(note: """
        ![](attachments/red.png)

        ## Folded

        ![](attachments/green.png)

        # Later

        \(filler)

        ![](attachments/blue.png)
        """, height: 400)
        let textView = try harness.textView
        try harness.foldHeading("## Folded")
        #expect(textView.visibleInlineImageFrames.map(\.range).count == 1)

        try harness.clickImage("![](attachments/red.png)")
        harness.press(.right)
        #expect(harness.displayedImage() == "green")
        harness.press(.right)
        #expect(harness.displayedImage() == "blue")
    }

    @Test("unsaved edits and staged images are browsed without saving")
    func unsavedContentIsBrowsed() async throws {
        let harness = try GalleryHarness(
            note: """
            ![](attachments/red.png)

            ![](attachments/green.png)
            """,
            staged: ["attachments/pasted.png": "cyan"]
        )
        let textView = try harness.textView
        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
        textView.insertText("\n\n![](attachments/pasted.png)", replacementRange: NSRange(location: end, length: 0))
        harness.settle()
        let typed = textView.string

        try harness.clickImage("![](attachments/green.png)")
        harness.press(.right)
        #expect(harness.displayedImage() == "cyan")
        #expect(harness.savedText == nil)
        #expect(textView.string == typed)
        #expect(!FileManager.default.fileExists(atPath: harness.noteURL.path))
    }

    @Test("Escape after browsing closes the gallery and returns focus to the unchanged note")
    func escapeRestoresEditor() async throws {
        let harness = try GalleryHarness(note: """
        ![](attachments/red.png)

        ![](attachments/green.png)
        """)
        let textView = try harness.textView
        let original = textView.string

        try harness.clickImage("![](attachments/red.png)")
        harness.press(.right)
        #expect(harness.displayedImage() == "green")
        harness.pressEscape()
        await flushMainQueue()
        harness.settle()

        #expect(harness.state.content == nil)
        #expect(harness.displayedImage() == nil)
        #expect(harness.window.firstResponder === textView)
        #expect(textView.string == original)
        #expect(harness.textChanges == 0)
    }

    @Test("failed local images show an error and remain reachable with keys and buttons",
          arguments: ["missing.png", "corrupt.png"])
    func failedOccurrencesStayNavigable(filename: String) async throws {
        let harness = try GalleryHarness(note: """
        # Available

        ![](attachments/red.png)

        # Broken

        ## Detail

        ![](attachments/\(filename))

        # Later

        ![](attachments/blue.png)
        """)
        if filename == "corrupt.png" {
            try Data("not an image".utf8).write(
                to: harness.directory.appending(path: "attachments/corrupt.png")
            )
        }
        let textView = try harness.textView
        let original = textView.string

        try harness.clickImage("![](attachments/red.png)")
        #expect(harness.displayedImage() == "red")
        #expect(harness.breadcrumb() == "Available")
        #expect(harness.errorFrame() == nil)
        harness.press(.right)
        #expect(harness.errorFrame() != nil)
        #expect(harness.displayedImage() == nil)
        #expect(harness.breadcrumb() == "Broken → Detail")
        #expect(try harness.breadcrumbIsAboveError())
        #expect(try harness.button(GalleryHarness.previous).isEnabled)
        #expect(try harness.button(GalleryHarness.next).isEnabled)

        harness.press(.right)
        #expect(harness.displayedImage() == "blue")
        #expect(harness.breadcrumb() == "Later")
        #expect(harness.errorFrame() == nil)
        harness.press(.left)
        #expect(harness.errorFrame() != nil)
        #expect(harness.breadcrumb() == "Broken → Detail")
        #expect(harness.displayedImage() == nil)
        harness.press(.left)
        #expect(harness.displayedImage() == "red")
        #expect(harness.breadcrumb() == "Available")
        #expect(harness.errorFrame() == nil)

        try harness.clickButton(GalleryHarness.next)
        #expect(harness.errorFrame() != nil)
        #expect(harness.breadcrumb() == "Broken → Detail")
        #expect(harness.displayedImage() == nil)
        try harness.clickButton(GalleryHarness.next)
        #expect(harness.displayedImage() == "blue")
        #expect(harness.breadcrumb() == "Later")
        #expect(harness.errorFrame() == nil)
        try harness.clickButton(GalleryHarness.previous)
        #expect(harness.errorFrame() != nil)
        #expect(harness.breadcrumb() == "Broken → Detail")
        #expect(harness.displayedImage() == nil)
        try harness.clickButton(GalleryHarness.previous)
        #expect(harness.displayedImage() == "red")
        #expect(harness.breadcrumb() == "Available")
        #expect(harness.errorFrame() == nil)
        #expect(textView.string == original)
        #expect(harness.textChanges == 0)
        #expect(harness.savedText == nil)
    }

    @Test("failed endpoints do not wrap and keep the error visible through resizing and Escape")
    func failedEndpointsResizeAndDismiss() async throws {
        let harness = try GalleryHarness(note: """
        ![](attachments/missing-first.png)

        # Available

        ![](attachments/green.png)

        # Broken end

        ![](attachments/missing-last.png)
        """)
        let textView = try harness.textView
        let original = textView.string

        try harness.clickImage("![](attachments/green.png)")
        harness.press(.left)
        #expect(harness.errorFrame() != nil)
        #expect(harness.displayedImage() == nil)
        #expect(harness.breadcrumb() == nil)
        #expect(try harness.button(GalleryHarness.previous).isEnabled == false)
        #expect(try harness.button(GalleryHarness.next).isEnabled)
        harness.press(.left)
        harness.press(.left)
        try harness.clickButton(GalleryHarness.previous)
        #expect(harness.errorFrame() != nil)
        #expect(try harness.button(GalleryHarness.previous).isEnabled == false)

        harness.window.setContentSize(NSSize(width: 440, height: 300))
        harness.settle()
        let error = try #require(harness.errorFrame())
        #expect(harness.window.contentLayoutRect.contains(error))
        #expect(abs(error.midX - harness.window.contentLayoutRect.midX) < 2)
        #expect(abs(error.midY - harness.window.contentLayoutRect.midY) < 2)

        try harness.clickButton(GalleryHarness.next)
        #expect(harness.displayedImage() == "green")
        #expect(harness.breadcrumb() == "Available")
        #expect(harness.errorFrame() == nil)
        try harness.clickButton(GalleryHarness.next)
        #expect(harness.errorFrame() != nil)
        #expect(harness.displayedImage() == nil)
        #expect(harness.breadcrumb() == "Broken end")
        #expect(try harness.breadcrumbIsAboveError())
        #expect(try harness.button(GalleryHarness.previous).isEnabled)
        #expect(try harness.button(GalleryHarness.next).isEnabled == false)
        harness.press(.right)
        harness.press(.right)
        try harness.clickButton(GalleryHarness.next)
        #expect(harness.errorFrame() != nil)
        #expect(try harness.button(GalleryHarness.next).isEnabled == false)

        harness.pressEscape()
        await flushMainQueue()
        harness.settle()
        #expect(harness.errorFrame() == nil)
        #expect(harness.breadcrumb() == nil)
        #expect(harness.window.firstResponder === textView)
        #expect(textView.string == original)
        #expect(harness.textChanges == 0)
        #expect(harness.savedText == nil)
    }
}

// MARK: - Harness

@MainActor
private final class GalleryHarness {
    enum Arrow { case left, right }

    static let previous = "Předchozí obrázek"
    static let next = "Další obrázek"

    /// Fixture images, each with its own aspect ratio so the preview's drawn
    /// frame tells which one it shows.
    static let images: [String: (width: Int, height: Int)] = [
        "red": (80, 20),
        "green": (60, 30),
        "blue": (30, 30),
        "yellow": (20, 40),
        "magenta": (10, 40),
        "cyan": (45, 30),
    ]

    let window: NSWindow
    let hostingView: NSHostingView<GalleryHarnessView>
    let state: GalleryHarnessState
    let directory: URL
    let note: String
    let noteURL: URL
    var savedText: String? { try? String(contentsOf: noteURL, encoding: .utf8) }
    var textChanges: Int { state.textChanges }

    var textView: MarkdownTextView {
        get throws {
            try #require(allSubviews(of: hostingView).compactMap { $0 as? MarkdownTextView }.first)
        }
    }

    /// A note at `<temp>/note.md` with an `attachments/<name>.png` file for each
    /// fixture image. `staged` images (source to fixture name) exist only in
    /// memory, like those pasted into a note that was never saved.
    init(
        note: String,
        staged: [String: String] = [:],
        height: CGFloat = 600,
        notePath: String = "note.md"
    ) throws {
        self.note = note
        directory = FileManager.default.temporaryDirectory
            .appending(path: "image-gallery-\(UUID().uuidString)", directoryHint: .isDirectory)
        noteURL = directory.appending(path: notePath)
        let attachments = noteURL.deletingLastPathComponent().appending(path: "attachments", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        for (name, size) in Self.images {
            try #require(Self.png(size)).write(to: attachments.appending(path: "\(name).png"))
        }
        var stagedData: [String: Data] = [:]
        for (source, name) in staged {
            stagedData[source] = try #require(Self.png(try #require(Self.images[name])))
        }

        state = GalleryHarnessState()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: height),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        hostingView = NSHostingView(
            rootView: GalleryHarnessView(
                note: note,
                noteURL: noteURL,
                staged: stagedData,
                state: state
            )
        )
        hostingView.frame = window.contentLayoutRect
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        settle()
        // As while editing the note, the editor has focus before an image is clicked.
        window.makeFirstResponder(try textView)
        settle()
    }

    deinit {
        MainActor.assumeIsolated { window.close() }
        try? FileManager.default.removeItem(at: directory)
    }

    func settle() {
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
    }

    func showTimeline(for tag: String) async throws {
        try note.write(to: noteURL, atomically: true, encoding: .utf8)
        let databaseURL = directory.appending(path: "index.sqlite")
        let index = SearchIndex(vault: Vault(rootURL: directory), databaseURL: databaseURL)
        try await index.synchronize()
        let reopened = SearchIndex(vault: Vault(rootURL: directory), databaseURL: databaseURL)
        state.timelineSection = try #require(try await reopened.tagTimeline(for: tag).first?.sections.first)
        await flushMainQueue()
        settle()
        window.makeFirstResponder(try textView)
    }

    /// Selects the editor's actual context-menu folding command, avoiding
    /// NSButtonCell's nested click-animation run loop.
    func foldHeading(_ heading: String) throws {
        let textView = try textView
        let range = (textView.string as NSString).range(of: heading)
        try #require(range.location != NSNotFound)
        let rect = textView.rect(forCharacterRange: range)
        let point = textView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let menu = try #require(textView.menu(for: mouseEvent(.rightMouseDown, at: point)))
        let index = menu.indexOfItem(withTitle: "Sbalit nebo rozbalit nadpis")
        try #require(index >= 0)
        menu.performActionForItem(at: index)
        settle()
    }

    /// Clicks the inline image drawn for the `occurrence`-th (0-based) match of
    /// `markdown`, scrolling it into view first.
    func clickImage(_ markdown: String, occurrence: Int = 0) throws {
        let textView = try textView
        let text = textView.string as NSString
        var searchStart = 0
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0...occurrence {
            found = text.range(
                of: markdown,
                range: NSRange(location: searchStart, length: text.length - searchStart)
            )
            try #require(found.location != NSNotFound, "\(markdown) occurs fewer than \(occurrence + 1) times")
            searchStart = found.upperBound
        }
        textView.scrollRangeToVisible(found)
        settle()
        let frame = try #require(
            textView.visibleInlineImageFrames.first { NSLocationInRange(found.location, $0.range) }?.frame,
            "no inline image drawn for \(markdown)"
        )
        let point = textView.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        // The test process is never active, so its window is not key and
        // AppKit would swallow a first click on the editor; deliver it to
        // the view the window hit-tests, as a click in the key window would.
        let content = try #require(window.contentView)
        let frameView = try #require(content.superview)
        let hit = try #require(content.hitTest(frameView.convert(point, from: nil)))
        hit.mouseDown(with: mouseEvent(.leftMouseDown, at: point))
        hit.mouseUp(with: mouseEvent(.leftMouseUp, at: point))
        settle()
    }

    func press(_ arrow: Arrow) {
        let scalar = arrow == .left ? NSLeftArrowFunctionKey : NSRightArrowFunctionKey
        let characters = String(Character(UnicodeScalar(scalar)!))
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.numericPad, .function],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: arrow == .left ? 123 : 124
        )!
        window.sendEvent(event)
        settle()
    }

    func pressEscape() {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        )!
        window.sendEvent(event)
        settle()
    }

    func click(at point: NSPoint) {
        window.sendEvent(mouseEvent(.leftMouseDown, at: point))
        window.sendEvent(mouseEvent(.leftMouseUp, at: point))
        settle()
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: type == .leftMouseDown ? 1 : 0
        )!
    }

    /// The fixture image the enlarged preview shows, recognised by the aspect
    /// ratio it is drawn with; nil when the preview shows no image.
    func displayedImage() -> String? {
        hostingView.layoutSubtreeIfNeeded()
        guard let view = allSubviews(of: hostingView)
            .compactMap({ $0 as? NSImageView })
            .first(where: { $0.accessibilityLabel() == "Náhled obrázku" }),
            view.image != nil, view.frame.width > 0, view.frame.height > 0 else { return nil }
        let ratio = view.frame.width / view.frame.height
        return Self.images.first {
            abs(CGFloat($0.value.width) / CGFloat($0.value.height) - ratio) < 0.05
        }?.key
    }

    /// The rendered error's frame, observed through its visible label.
    func errorFrame() -> NSRect? {
        guard let label = allSubviews(of: hostingView)
            .compactMap({ $0 as? NSTextField })
            .first(where: { $0.stringValue == "Obrázek nelze načíst" }),
            !label.isHiddenOrHasHiddenAncestor,
            label.visibleRect.width > 0, label.visibleRect.height > 0 else { return nil }
        return label.convert(label.bounds, to: nil)
    }

    /// The preview's control labelled `label`.
    func button(_ label: String) throws -> NSButton {
        try #require(
            allSubviews(of: hostingView)
                .compactMap { $0 as? NSButton }
                .first { $0.accessibilityLabel() == label },
            "no \(label) button"
        )
    }

    /// Clicks the preview's control labelled `label` where it is drawn.
    func clickButton(_ label: String) throws {
        let button = try button(label)
        click(at: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
    }

    /// The heading breadcrumb the preview shows; nil when it shows none.
    func breadcrumb() -> String? {
        hostingView.layoutSubtreeIfNeeded()
        guard let field = breadcrumbField(), !field.stringValue.isEmpty else { return nil }
        return field.stringValue
    }

    func breadcrumbFontSize() throws -> CGFloat {
        let field = try #require(breadcrumbField())
        return try #require(field.font).pointSize
    }

    /// Whether the breadcrumb is drawn inside the window, entirely above the image.
    func breadcrumbIsAboveImage() throws -> Bool {
        hostingView.layoutSubtreeIfNeeded()
        let field = try #require(breadcrumbField())
        let image = try #require(previewImageView())
        let crumb = field.convert(field.bounds, to: nil)
        let picture = image.convert(image.bounds, to: nil)
        return crumb.minY >= picture.maxY
            && crumb.maxY <= hostingView.convert(hostingView.bounds, to: nil).maxY
    }

    func breadcrumbIsAboveError() throws -> Bool {
        let field = try #require(breadcrumbField())
        let error = try #require(errorFrame())
        let crumb = field.convert(field.bounds, to: nil)
        return crumb.minY >= error.maxY
            && crumb.maxY <= hostingView.convert(hostingView.bounds, to: nil).maxY
    }

    func clickBreadcrumb() throws {
        let field = try #require(breadcrumbField())
        click(at: field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil))
    }

    private func breadcrumbField() -> NSTextField? {
        allSubviews(of: hostingView)
            .compactMap { $0 as? NSTextField }
            .first {
                $0.accessibilityLabel() == "Nadpisy obrázku" && !$0.isHiddenOrHasHiddenAncestor
                    && $0.frame.width > 0 && $0.frame.height > 0
            }
    }

    private func previewImageView() -> NSImageView? {
        allSubviews(of: hostingView)
            .compactMap { $0 as? NSImageView }
            .first { $0.accessibilityLabel() == "Náhled obrázku" }
    }

    static func png(_ size: (width: Int, height: Int)) -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size.width, pixelsHigh: size.height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

@MainActor
private final class GalleryHarnessState: ObservableObject {
    @Published var content: ImagePreviewContent?
    @Published var timelineSection: TagTimelineSection?
    var textChanges = 0
}

@MainActor
private struct GalleryHarnessView: View {
    let note: String
    let noteURL: URL
    let staged: [String: Data]
    @ObservedObject var state: GalleryHarnessState

    var body: some View {
        ZStack {
            if let section = state.timelineSection {
                ScrollView {
                    ReadOnlyMarkdownView(
                        markdown: section.markdown,
                        noteURL: noteURL,
                        enclosingHeadings: section.enclosingHeadings,
                        onOpenImagePreview: { state.content = $0 }
                    )
                }
            } else {
                MarkdownEditor(
                    documentID: "image-gallery-test",
                    initialText: { note },
                    isInteractionEnabled: state.content == nil,
                    noteURL: noteURL,
                    inlineImageData: { staged[$0] },
                    onOpenImagePreview: { state.content = $0 },
                    onTextChange: { _ in state.textChanges += 1 }
                )
            }

            if let content = state.content {
                ImagePreviewOverlay(content: content) {
                    state.content = nil
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
private func flushMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}
