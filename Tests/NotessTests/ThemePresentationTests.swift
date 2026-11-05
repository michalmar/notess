import AppKit
import SwiftUI
import Testing
@testable import Notess
@testable import NotessCore
@testable import NotessEditor

@MainActor
@Suite("Native theme presentation", .serialized, .tags(.hostedUI), .enabled(if: ProcessInfo.processInfo.environment["NOTESS_HOSTED_UI"] == "1"))
struct ThemePresentationTests {
    @Test("the Settings selector applies native Light, Dark and System to existing and new windows")
    func settingsSelection() async throws {
        let fixture = try SearchPresentationFixture()
        try fixture.write("# Plan\n\nNative appearance.\n", to: "Notes/Plan.md")
        try fixture.write("# Alice\n\nRead-only Brain Note.\n", to: "_brain/Alice.md")
        let harness = try await fixture.makeHarness(opening: "Notes/Plan.md")
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        let settingsWindow = makeSettingsWindow(model: harness.model)
        defer { settingsWindow.close() }
        await harness.settle()
        let picker = try themePicker(in: settingsWindow)
        #expect(picker.itemTitles == ["Podle systému", "Light", "Dark"])
        #expect(picker.isEnabled)
        #expect(picker.accessibilityLabel() == "Téma")
        #expect(settingsWindow.makeFirstResponder(picker), "the selector supports native keyboard focus")
        let existingSecond = SearchPresentationHarness(model: harness.model)
        await existingSecond.settle()

        for (title, expected): (String, NSAppearance.Name) in [("Dark", .darkAqua), ("Light", .aqua)] {
            try select(title, in: picker)
            await harness.settle()

            #expect(harness.model.settings.theme.rawValue == title.lowercased())
            #expect(harness.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
            #expect(settingsWindow.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
            #expect(existingSecond.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
            let editor = try #require(harness.editor)
            #expect(editor.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
            let background = resolved(editor.backgroundColor, in: editor.effectiveAppearance)
            #expect(expected == .aqua ? background.whiteComponent > 0.8 : background.whiteComponent < 0.3)
            let text = resolved(editor.markdownStyle.colors.text, in: editor.effectiveAppearance)
            #expect(expected == .aqua ? text.whiteComponent < 0.3 : text.whiteComponent > 0.8)
            #expect(editor.textLayoutManager != nil)

            let second = SearchPresentationHarness(model: harness.model)
            await second.settle()
            #expect(second.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
            let dialog = NSOpenPanel()
            #expect(dialog.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
            #expect(!harness.model.hasUnsavedChanges)
            second.window.close()
            harness.window.makeKeyAndOrderFront(nil)

            _ = harness.model.openExistingNote(relativePath: "_brain/Alice.md")
            await harness.settle()
            let readOnly = try #require(harness.editor)
            #expect(!readOnly.isEditable)
            #expect(readOnly.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
            #expect(resolved(readOnly.backgroundColor, in: readOnly.effectiveAppearance) == background)
            _ = harness.model.openExistingNote(relativePath: "Notes/Plan.md")
            harness.model.isBrainConversationPresented = true
            await harness.settle()
            let input = try #require(descendants(of: harness.hostingView).compactMap { $0 as? NSTextField }
                .first { $0.placeholderString == BrainConversationPanel.inputPlaceholder })
            #expect(input.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
            harness.model.isBrainConversationPresented = false
            harness.model.presentSearch()
            await harness.settle()
            let search = try #require(descendants(of: harness.hostingView).compactMap { $0 as? NSTextField }
                .first { $0.placeholderString?.hasPrefix("Hledat v uložených") == true })
            #expect(search.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
            harness.model.isSearchPresented = false
            await harness.settle()
        }

        let nextVault = try SearchPresentationFixture()
        try nextVault.write("A different Vault.\n", to: "Notes/Other.md")
        harness.model.chooseVault(at: nextVault.rootURL)
        _ = harness.model.openExistingNote(relativePath: "Notes/Other.md")
        await harness.settle()
        #expect(harness.model.settings.theme == .light)
        #expect(harness.editor?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)

        try select("Podle systému", in: picker)
        await harness.settle()
        #expect(harness.model.settings.theme == .system)
        #expect(NSApp.appearance == nil, "System removes the override so macOS appearance changes propagate")
        #expect(harness.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            == NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]))
    }

    @Test("switching through Settings preserves an unsaved editing session and text geometry")
    func editingSession() async throws {
        let fixture = try SearchPresentationFixture()
        let original = "# Heading\n\n## Section\n\n**Bold** and *italic*.\n\n"
            + String(repeating: "A paragraph to keep the note scrollable.\n\n", count: 100)
        try fixture.write(original, to: "Notes/Plan.md")
        let harness = try await fixture.makeHarness(opening: "Notes/Plan.md")
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        harness.model.settings.editorFont = EditorFont(name: "Menlo", size: 18)
        harness.model.settings.textZoom = 1.3
        await harness.settle()
        let editor = try #require(harness.editor)
        let document = try #require(harness.model.document)
        let undo = try #require(editor.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.insertText("First edit. ", replacementRange: NSRange(location: 40, length: 0))
        undo.endUndoGrouping()
        let firstEdit = editor.string
        undo.beginUndoGrouping()
        editor.insertText("Second edit. ", replacementRange: NSRange(location: 100, length: 0))
        undo.endUndoGrouping()
        let secondEdit = editor.string
        undo.undo()
        await harness.settle()
        #expect(document.text == firstEdit)
        #expect(document.hasUnsavedChanges)
        #expect(undo.canUndo && undo.canRedo)
        editor.setSelectedRange(NSRange(location: 200, length: 12))
        let scrollView = try #require(editor.enclosingScrollView)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 300))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        await harness.settle()
        let selection = editor.selectedRange()
        let scroll = try #require(editor.enclosingScrollView).contentView.bounds.origin
        #expect(scroll.y > 0)
        let storage = try #require(editor.textStorage)
        let formatted = NSAttributedString(attributedString: storage)
        let frame = harness.window.frame
        let editorSize = editor.frame.size
        let layout = try #require(editor.textLayoutManager).usageBoundsForTextContainer
        let headingFont = try #require(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        #expect(headingFont.pointSize > 23.4)

        let settingsWindow = makeSettingsWindow(model: harness.model)
        defer { settingsWindow.close() }
        await harness.settle()
        let picker = try themePicker(in: settingsWindow)
        for title in ["Dark", "Light", "Podle systému"] {
            try select(title, in: picker)
            await harness.settle()
            #expect(harness.editor === editor)
            #expect(harness.model.document === document)
            #expect(editor.string == firstEdit)
            #expect(document.text == firstEdit)
            #expect(document.hasUnsavedChanges)
            #expect(editor.selectedRange() == selection)
            #expect(editor.enclosingScrollView?.contentView.bounds.origin == scroll)
            #expect(undo.canUndo && undo.canRedo)
            #expect(storage.isEqual(to: formatted), "font family, sizes, heading scale, emphasis and paragraph spacing stay intact")
            #expect(harness.model.settings.editorFont == EditorFont(name: "Menlo", size: 18))
            #expect(harness.model.settings.textZoom == 1.3)
            #expect(harness.window.frame == frame)
            #expect(editor.frame.size == editorSize)
            #expect(editor.textLayoutManager?.usageBoundsForTextContainer == layout)
            #expect(editor.textLayoutManager != nil)
        }

        undo.undo()
        await harness.settle()
        #expect(document.text == original)
        #expect(!document.hasUnsavedChanges)
        undo.redo()
        await harness.settle()
        #expect(document.text == firstEdit)
        undo.redo()
        await harness.settle()
        #expect(document.text == secondEdit)
        #expect(document.hasUnsavedChanges)
    }
}

@MainActor
private func makeSettingsWindow(model: AppModel) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 540, height: 650),
        styleMask: [.titled, .resizable],
        backing: .buffered,
        defer: true
    )
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: SettingsView(model: model))
    window.makeKeyAndOrderFront(nil)
    return window
}

@MainActor
private func themePicker(in window: NSWindow) throws -> NSPopUpButton {
    let content = try #require(window.contentView)
    return try #require(descendants(of: content).compactMap { $0 as? NSPopUpButton }
        .first { $0.accessibilityLabel() == "Téma" })
}

@MainActor
private func select(_ title: String, in picker: NSPopUpButton) throws {
    picker.selectItem(withTitle: title)
    try #require(picker.sendAction(picker.action, to: picker.target))
}

@MainActor
private func descendants(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { descendants(of: $0) }
}

@MainActor
private func resolved(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
    var result = color
    appearance.performAsCurrentDrawingAppearance {
        result = color.usingColorSpace(.genericGray) ?? color
    }
    return result
}
