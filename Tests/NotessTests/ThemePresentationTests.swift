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
        #expect(picker.itemTitles == ["Podle systému", "Light", "Dark", "Noir Essence"])
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
        for title in ["Dark", "Noir Essence", "Light", "Noir Essence", "Podle systému"] {
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
            #expect(storage.isEqual(to: formatted), "fonts, heading scale, emphasis, spacing and the theme-following colours stay intact: no restyle")
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

    @Test("Noir Essence paints a readable cream and orange palette that stays light and gives way to native themes")
    func noirEssence() async throws {
        let fixture = try SearchPresentationFixture()
        try fixture.write(Self.markdownRoles, to: "Notes/Plan.md")
        try fixture.write("# Alice\n\nA Free Note.\n", to: "Notes/Alice.md")
        let harness = try await fixture.makeHarness(opening: "Notes/Plan.md")
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        let settingsWindow = makeSettingsWindow(model: harness.model)
        defer { settingsWindow.close() }
        await harness.settle()
        let picker = try themePicker(in: settingsWindow)
        let existingSecond = SearchPresentationHarness(model: harness.model)
        await existingSecond.settle()
        try select("Dark", in: picker)
        await harness.settle()

        try select("Noir Essence", in: picker)
        await harness.settle()

        #expect(harness.model.settings.theme == .noirEssence)
        #expect(NSApp.appearance?.name == .aqua, "Noir Essence is light even while macOS or the previous theme is dark")
        let newSecond = SearchPresentationHarness(model: harness.model)
        await newSecond.settle()
        defer { newSecond.window.close() }
        for window in [harness.window, settingsWindow, existingSecond.window, newSecond.window] {
            #expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
        }
        #expect(NSOpenPanel().effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua, "native dialogs stay native and light")
        harness.window.makeKeyAndOrderFront(nil)
        await harness.settle()

        let editor = try #require(harness.editor)
        let appearance = editor.effectiveAppearance
        let background = srgb(editor.backgroundColor, in: appearance)
        #expect(abs(background.redComponent - 0xf7 / 255) < 0.02
            && abs(background.greenComponent - 0xf3 / 255) < 0.02
            && abs(background.blueComponent - 0xea / 255) < 0.02, "the cream reference background")
        for (window, name) in [(harness.window, "main"), (newSecond.window, "new")] {
            let main = try #require(SearchPresentationHarness.editor(in: window))
            #expect(srgb(main.backgroundColor, in: main.effectiveAppearance) == background, "\(name) window editor")
        }
        let storage = try #require(editor.textStorage)
        func foreground(_ text: String) throws -> NSColor {
            let range = (editor.string as NSString).range(of: text)
            try #require(range.location != NSNotFound)
            return try #require(storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor)
        }
        let roles: [(String, NSColor)] = [
            ("text", try foreground("Body")), ("link", try foreground("site")),
            ("Wiki-link", try foreground("Alice")), ("Tag", try foreground("project")),
            ("quotation", try foreground("A quotation")), ("completed Task", try foreground("Done task")),
            ("table", try foreground("Name")),
        ]
        let codeRange = (editor.string as NSString).range(of: "code")
        let codeBackground = try #require(storage.attribute(.backgroundColor, at: codeRange.location, effectiveRange: nil) as? NSColor)
        let marker = try foreground("# ")
        let checkbox = try #require(descendants(of: editor).compactMap { $0 as? NSButton }
            .first { String(describing: type(of: $0)) == "TaskCheckboxButton" }?.contentTintColor)
        let selection = try #require(editor.selectedTextAttributes[.backgroundColor] as? NSColor)

        defer { ThemePalette.increasedContrastOverride = nil }
        for (increased, minimum) in [(false, 4.5), (true, 7.0)] {
            ThemePalette.increasedContrastOverride = increased
            let variant = appearance
            let surface = srgb(editor.backgroundColor, in: variant)
            for (role, color) in roles {
                #expect(contrast(color, on: surface, in: variant) >= minimum, "\(role) is readable")
            }
            let code = composite(codeBackground, over: surface, in: variant)
            #expect(contrast(try foreground("code"), on: code, in: variant) >= minimum, "code is readable on its surface")
            #expect(colorDistance(code, surface) > 0.03, "code has a visible surface")
            #expect(contrast(marker, on: surface, in: variant) >= (minimum == 7 ? 4.5 : 2), "Markdown markers stay visible")
            #expect(contrast(marker, on: surface, in: variant) < contrast(roles[0].1, on: surface, in: variant), "markers stay muted")
            #expect(contrast(checkbox, on: surface, in: variant) >= 3, "Task checkboxes are visible")
            let selected = composite(selection, over: surface, in: variant)
            #expect(colorDistance(selected, surface) > 0.08, "selection is distinguishable")
            #expect(contrast(roles[0].1, on: selected, in: variant) >= minimum, "selected text stays readable")
        }
        ThemePalette.increasedContrastOverride = nil
        let semantic = roles.prefix(4).map { srgb($0.1, in: appearance) }
        for i in semantic.indices { for j in semantic.indices where i < j {
            #expect(colorDistance(semantic[i], semantic[j]) > 0.15, "\(roles[i].0) and \(roles[j].0) are distinguishable")
        } }
        let accent = srgb(checkbox, in: appearance)
        #expect(accent.redComponent > accent.blueComponent + 0.3, "the accent is orange, not the system accent")

        let tabBar = try #require(shellSample(above: editor, in: harness))
        #expect(isCream(tabBar), "the tab bar uses the palette: \(tabBar)")
        let sidebar = try #require(harness.tables.first.flatMap { sample(belowContentOf: $0, in: harness) })
        #expect(isCream(sidebar), "the sidebar uses the palette: \(sidebar)")
        let settings = try #require(settingsSample(in: settingsWindow))
        #expect(isCream(settings), "Settings use the palette: \(settings)")

        _ = harness.model.openExistingNote(relativePath: "Notes/Alice.md")
        await harness.settle()
        #expect(srgb(try #require(harness.editor).backgroundColor, in: appearance) == background, "newly opened notes")

        try select("Light", in: picker)
        await harness.settle()
        let light = try #require(harness.editor)
        #expect(NSApp.appearance?.name == .aqua)
        #expect(srgb(light.backgroundColor, in: light.effectiveAppearance) == srgb(.textBackgroundColor, in: light.effectiveAppearance))
        try expectNativeColors(light)
        let lightTabBar = try #require(shellSample(above: light, in: harness))
        #expect(!isCream(lightTabBar), "Light restores the native shell: \(lightTabBar)")

        try select("Noir Essence", in: picker)
        await harness.settle()
        let again = try #require(harness.editor)
        let alice = try #require(again.textStorage?.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor)
        #expect(colorDistance(srgb(alice, in: again.effectiveAppearance), srgb(roles[0].1, in: appearance)) < 0.01,
                "the same text colours re-resolve to the palette on the unchanged light appearance")
        #expect(isCream(srgb(again.backgroundColor, in: again.effectiveAppearance)))
        try select("Podle systému", in: picker)
        await harness.settle()
        #expect(NSApp.appearance == nil, "System resumes macOS tracking")
        try expectNativeColors(try #require(harness.editor))
        existingSecond.window.close()
    }

    private static let markdownRoles = """
        # Plan

        Body text with [site](https://example.com), [[Alice]] and #project.

        - [ ] Open task
        - [x] Done task

        > A quotation

        Inline `code` here.

        | Name | Value |
        | --- | --- |
        | a | b |

        """
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

extension SearchPresentationHarness {
    @MainActor
    static func editor(in window: NSWindow) -> MarkdownTextView? {
        window.contentView.flatMap { descendants(of: $0).compactMap { $0 as? MarkdownTextView }.first }
    }
}

/// Text attributes that determine typography and geometry, without colours.
@MainActor
private func srgb(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
    var result = color
    appearance.performAsCurrentDrawingAppearance {
        result = color.usingColorSpace(.sRGB) ?? color
    }
    return result
}

@MainActor
private func composite(_ color: NSColor, over surface: NSColor, in appearance: NSAppearance) -> NSColor {
    let top = srgb(color, in: appearance)
    let bottom = srgb(surface, in: appearance)
    let a = top.alphaComponent
    return NSColor(
        srgbRed: top.redComponent * a + bottom.redComponent * (1 - a),
        green: top.greenComponent * a + bottom.greenComponent * (1 - a),
        blue: top.blueComponent * a + bottom.blueComponent * (1 - a),
        alpha: 1
    )
}

/// The WCAG contrast ratio of a colour drawn over an opaque surface.
@MainActor
private func contrast(_ color: NSColor, on surface: NSColor, in appearance: NSAppearance) -> Double {
    let bottom = composite(surface, over: .white, in: appearance)
    let top = composite(color, over: bottom, in: appearance)
    func luminance(_ c: NSColor) -> Double {
        func channel(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }
    let (a, b) = (luminance(top), luminance(bottom))
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

private func colorDistance(_ a: NSColor, _ b: NSColor) -> Double {
    let (a, b) = (a.usingColorSpace(.sRGB)!, b.usingColorSpace(.sRGB)!)
    let dr = a.redComponent - b.redComponent, dg = a.greenComponent - b.greenComponent, db = a.blueComponent - b.blueComponent
    return Double((dr * dr + dg * dg + db * db).squareRoot())
}

/// Native themes show native colours and the system accent.
@MainActor
private func expectNativeColors(_ editor: NSTextView, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let appearance = editor.effectiveAppearance
    let storage = try #require(editor.textStorage)
    let text = (editor.string as NSString).range(of: "A Free Note")
    try #require(text.location != NSNotFound)
    let pairs: [(String, Any?, NSColor)] = [
        ("text", storage.attribute(.foregroundColor, at: text.location, effectiveRange: nil), .textColor),
        ("marker", storage.attribute(.foregroundColor, at: 0, effectiveRange: nil), .tertiaryLabelColor),
        ("background", editor.backgroundColor, .textBackgroundColor),
    ]
    for (role, color, native) in pairs {
        let color = try #require(color as? NSColor, sourceLocation: sourceLocation)
        #expect(colorDistance(srgb(color, in: appearance), srgb(native, in: appearance)) < 0.01, "native \(role)", sourceLocation: sourceLocation)
    }
    let plain = NSTextView()
    #expect(editor.selectedTextAttributes[.backgroundColor] as? NSColor == plain.selectedTextAttributes[.backgroundColor] as? NSColor, sourceLocation: sourceLocation)
    #expect(editor.insertionPointColor == plain.insertionPointColor, sourceLocation: sourceLocation)
}

/// A light, warm surface: cream, not native white or grey.
private func isCream(_ color: NSColor) -> Bool {
    let c = color.usingColorSpace(.sRGB)!
    return c.redComponent > 0.85 && c.redComponent - c.blueComponent > 0.03
}

/// The pixel a window actually renders at a point in window coordinates.
@MainActor
private func renderedColor(at point: NSPoint, in window: NSWindow) -> NSColor? {
    guard let view = window.contentView else { return nil }
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    let local = view.convert(point, from: nil)
    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
    let y = view.isFlipped ? local.y : view.bounds.height - local.y
    return rep.colorAt(x: Int(local.x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB)
}

/// The shell between the tab bar's tabs and the window edge, just above the editor.
@MainActor
private func shellSample(above editor: MarkdownTextView, in harness: SearchPresentationHarness) -> NSColor? {
    guard let scroll = editor.enclosingScrollView else { return nil }
    let frame = scroll.convert(scroll.bounds, to: nil)
    return renderedColor(at: NSPoint(x: frame.maxX - 30, y: frame.maxY + 14), in: harness.window)
}

/// Empty sidebar space below its rows.
@MainActor
private func sample(belowContentOf table: NSTableView, in harness: SearchPresentationHarness) -> NSColor? {
    guard let scroll = table.enclosingScrollView else { return nil }
    let frame = scroll.convert(scroll.bounds, to: nil)
    return renderedColor(at: NSPoint(x: frame.midX, y: frame.minY + 12), in: harness.window)
}

/// The Settings margin beside its sections; the content is 500 points wide and centred.
@MainActor
private func settingsSample(in window: NSWindow) -> NSColor? {
    guard let bounds = window.contentView?.bounds else { return nil }
    return renderedColor(at: NSPoint(x: bounds.midX - 244, y: bounds.midY), in: window)
}
