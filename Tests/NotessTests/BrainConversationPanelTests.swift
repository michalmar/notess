import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Notess
@testable import NotessCore
@testable import NotessEditor

@MainActor
@Suite("Brain Conversation panel", .serialized, .tags(.hostedUI), .enabled(if: ProcessInfo.processInfo.environment["NOTESS_HOSTED_UI"] == "1"))
struct BrainConversationPanelTests {
    @Test("conversation inline Markdown uses shared code and link roles while native themes remove custom colors")
    func themedAnswerMarkdown() async throws {
        let fixture = try PanelFixture()
        let harness = try await fixture.makeHarness()
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        harness.model.isBrainConversationPresented = true
        try await harness.waitUntil { harness.input != nil }
        let settingsWindow = harness.makeSettingsWindow()
        defer { settingsWindow.close() }
        await harness.settle()
        try harness.selectTheme("Noir Essence", in: settingsWindow)
        await harness.settle()
        try harness.capture("brain-empty")
        harness.model.askBrainConversation("How?")
        try await harness.waitUntil { harness.connections.made.first?.isPrompting == true }
        let answer = "Body **bold**, *italic*, `inline code`, [[_brain/Alice]] and [site](https://example.com)."
        harness.connections.last.send(.event(.answerChunk(answer)))
        harness.connections.last.send(.finish(.endTurn))
        try await harness.waitUntil { !harness.model.isAgentOperationActive }
        for theme in ["Noir Essence", "Light", "Noir Essence", "Dark", "Podle systému"] {
            try harness.selectTheme(theme, in: settingsWindow)
            await harness.settle()
            let count = try harness.panelPixelCount(hex: 0xEBE3D3)
            #expect(theme == "Noir Essence" ? count > 100 : count == 0, "only the custom theme gives rendered inline code its shared surface")
            #expect(harness.model.brainConversation.conversation.turns.last?.answer == answer)
            try harness.capture("brain-answer-\(harness.model.settings.theme.rawValue)")
        }
    }

    @Test("Noir Essence renders incomplete and failed answers with readable semantic status colors", arguments: [false, true])
    func themedStatusColors(incomplete: Bool) async throws {
        let fixture = try PanelFixture()
        let harness = try await fixture.makeHarness()
        let previousAppearance = NSApp.appearance
        defer {
            NSApp.appearance = previousAppearance
            ThemePalette.increasedContrastOverride = nil
        }
        harness.model.isBrainConversationPresented = true
        try await harness.waitUntil { harness.input != nil }
        harness.model.askBrainConversation("Explain the evidence")
        try await harness.waitUntil { harness.connections.made.first?.isPrompting == true }
        if incomplete {
            harness.connections.last.send(.event(.answerChunk("Partial evidence from [[_brain/Alice]].")))
            harness.connections.last.send(.finish(.maxTokens))
        } else {
            harness.connections.last.send(.fail(.agent("Evidence could not be read.")))
        }
        try await harness.waitUntil { !harness.model.isAgentOperationActive }
        let settingsWindow = harness.makeSettingsWindow()
        defer { settingsWindow.close() }
        await harness.settle()
        try harness.selectTheme("Noir Essence", in: settingsWindow)
        await harness.settle()
        for increased in [false, true] {
            ThemePalette.increasedContrastOverride = increased
            try harness.selectTheme("Light", in: settingsWindow)
            await harness.settle()
            try harness.selectTheme("Noir Essence", in: settingsWindow)
            await harness.settle()
            let expected: UInt32 = incomplete
                ? (increased ? 0x694500 : 0x8F5F0A)
                : (increased ? 0x8E2A25 : 0xB8423C)
            #expect(try harness.panelPixelCount(hex: expected) > 10, "the rendered status uses the readable \(incomplete ? "warning" : "error") role")
        }
        #expect(!harness.model.hasUnsavedChanges)
    }

    @Test("Settings recolors an open Brain Note and active conversation without changing drafts, sources or Agent work")
    func themeSwitchDuringConversation() async throws {
        let brainMarkdown = """
            # Alice

            Body **bold** and *italic*, [site](https://example.com), [[Plan]] and #project.

            - [ ] Open task
            - [x] Done task

            > A quotation

            Inline `code`.

            | Name | Value |
            | --- | --- |
            | a | b |

            """ + String(repeating: "\nMore supporting facts.\n", count: 100)
        let fixture = try PanelFixture(brainMarkdown: brainMarkdown)
        let harness = try await fixture.makeHarness()
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        _ = harness.model.openExistingNote(relativePath: "_brain/Alice.md")
        harness.model.isBrainConversationPresented = true
        try await harness.waitUntil { harness.focusedInput != nil }
        harness.model.askBrainConversation("What does Alice know?")
        try await harness.waitUntil { harness.connections.made.first?.isPrompting == true }
        let answer = "A fact from [[_brain/Alice]] and [the web](https://example.com).\n"
            + String(repeating: "A paragraph of supporting detail.\n\n", count: 40)
        harness.connections.last.send(.event(.answerChunk(answer)))
        let source = BrainConversationEvidence.noteURL(target: "_brain/Alice", section: nil)
        let web = try #require(URL(string: "https://example.com"))
        try await harness.waitUntil { harness.sourceButton(source) != nil && harness.sourceButton(web) != nil }
        harness.type("Unsent follow-up")
        await harness.settle()
        let input = try #require(harness.input)
        let editor = try #require(harness.editor)
        let document = try #require(harness.model.document)
        let text = editor.string
        let formatted = NSAttributedString(attributedString: try #require(editor.textStorage))
        editor.setSelectedRange(NSRange(location: 200, length: 8))
        let noteScroll = try #require(editor.enclosingScrollView)
        noteScroll.contentView.scroll(to: NSPoint(x: 0, y: 180))
        noteScroll.reflectScrolledClipView(noteScroll.contentView)
        await harness.settle()
        let noteOrigin = noteScroll.contentView.bounds.origin
        let noteSelection = editor.selectedRange()
        let layout = try #require(editor.textLayoutManager).usageBoundsForTextContainer
        #expect(noteOrigin.y > 0)
        let selected = harness.model.brainConversation.conversation.id
        let baseline = harness.model.lastSuccessfulBrainRun
        let connection = harness.connections.last
        let sourceButton = try #require(harness.sourceButton(source))
        let transcript = try #require(harness.scrollViews.first { $0 !== editor.enclosingScrollView && $0.documentView?.bounds.height ?? 0 > 700 })
        transcript.contentView.scroll(to: NSPoint(x: 0, y: 120))
        transcript.reflectScrolledClipView(transcript.contentView)
        await harness.settle()
        let scroll = transcript.contentView.bounds.origin
        #expect(scroll.y > 0)
        let settingsWindow = harness.makeSettingsWindow()
        defer { settingsWindow.close() }
        await harness.settle()

        for theme in ["Noir Essence", "Dark", "Light", "Noir Essence", "Podle systému"] {
            try harness.selectTheme(theme, in: settingsWindow)
            await harness.settle()
            #expect(harness.model.document === document)
            #expect(harness.editor === editor)
            #expect(!editor.isEditable && document.isReadOnly)
            #expect(editor.string == text && document.text == text)
            #expect(editor.textStorage?.isEqual(to: formatted) == true, "read-only text is redrawn, not restyled")
            #expect(editor.selectedRange() == noteSelection)
            #expect(noteScroll.contentView.bounds.origin == noteOrigin)
            #expect(editor.textLayoutManager?.usageBoundsForTextContainer == layout)
            #expect(!document.hasUnsavedChanges)
            #expect(harness.input === input && input.stringValue == "Unsent follow-up")
            #expect(harness.model.brainConversation.conversation.id == selected)
            #expect(harness.model.brainConversation.conversation.turns.last?.answer == answer)
            #expect(transcript.contentView.bounds.origin == scroll)
            #expect(harness.sourceButton(source) === sourceButton)
            #expect(harness.model.isAgentOperationActive)
            #expect(harness.control(draft: input.stringValue) == .stop(isEnabled: true))
            #expect(harness.connections.made.count == 1 && connection.prompts.count == 1)
            #expect(connection.cancelCount == 0 && connection.closeCount == 0)
            #expect(harness.model.lastSuccessfulBrainRun == baseline)

            if theme == "Noir Essence" {
                let color = try #require(harness.renderedColor(
                    at: NSPoint(x: -6, y: input.bounds.midY), in: input
                ))
                #expect(abs(color.redComponent - 247.0 / 255) < 0.02
                    && abs(color.greenComponent - 243.0 / 255) < 0.02
                    && abs(color.blueComponent - 234.0 / 255) < 0.02, "the rendered source panel uses the cream surface, not native white")
                let noteTint = try #require(sourceButton.contentTintColor?.usingColorSpace(.sRGB))
                let webTint = try #require(harness.sourceButton(web)?.contentTintColor?.usingColorSpace(.sRGB))
                #expect(noteTint.redComponent > noteTint.blueComponent, "note evidence uses the shared Wiki-link role")
                #expect(webTint.blueComponent > webTint.redComponent, "web evidence uses the shared link role")
                try harness.capture("brain-active")
                let newWindow = PanelHarness(model: harness.model, connections: harness.connections)
                await newWindow.settle()
                let newEditor = try #require(newWindow.editor)
                #expect(!newEditor.isEditable)
                #expect(newEditor.backgroundColor == editor.backgroundColor, "new Brain views use the current theme")
                #expect(newWindow.sourceButton(source)?.contentTintColor == sourceButton.contentTintColor)
                newWindow.window.close()
            } else {
                #expect(sourceButton.contentTintColor == .linkColor, "native themes restore native link controls")
            }
        }
        #expect(try String(contentsOf: document.fileURL, encoding: .utf8) == text)
        connection.send(.finish(.endTurn))
        try await harness.waitUntil { !harness.model.isAgentOperationActive }
    }

    @Test("identical or truncated first-question labels keep one selectable item per conversation", arguments: [false, true])
    func duplicateConversationTitles(truncated: Bool) async throws {
        let fixture = try PanelFixture()
        let harness = try await fixture.makeHarness()
        harness.model.isBrainConversationPresented = true
        try await harness.waitUntil { harness.conversationPicker != nil }
        let prefix = String(repeating: "Q", count: 81)
        let questions = truncated
            ? [prefix + " first", "Other question?", prefix + " second"]
            : ["Same question?", "Other question?", "Same question?"]
        for (index, question) in questions.enumerated() {
            if index > 0 {
                harness.model.createBrainConversation()
                try await harness.waitUntil { !harness.model.isAgentOperationActive }
            }
            harness.model.askBrainConversation(question)
            try await harness.waitUntil {
                harness.connections.made.count == index + 1 && harness.connections.made.last?.isPrompting == true
            }
            harness.connections.last.send(.finish(.endTurn))
            try await harness.waitUntil { !harness.model.isAgentOperationActive }
        }
        await harness.settle()
        let picker = try #require(harness.conversationPicker)
        #expect(picker.numberOfItems == 3)
        let ids = harness.model.brainConversation.conversations.map(\.id)
        for index in ids.indices {
            picker.selectItem(at: index)
            try #require(picker.sendAction(picker.action, to: picker.target))
            await harness.settle()
            #expect(harness.model.brainConversation.conversation.id == ids[index])
            #expect(harness.model.brainConversation.conversation.turns.first?.question == questions[index])
            #expect(picker.indexOfSelectedItem == index)
        }
    }

    @Test("native creation and selection focus the question field and keep unsent drafts in their own conversation")
    func conversationSelector() async throws {
        let fixture = try PanelFixture()
        let harness = try await fixture.makeHarness()
        let editor = try #require(harness.editor)
        let original = editor.string
        harness.model.isBrainConversationPresented = true
        try await harness.waitUntil { harness.focusedInput != nil && harness.conversationPicker != nil }
        let firstID = harness.model.brainConversation.conversation.id
        harness.type("First draft")
        await harness.settle()
        let create = try #require(harness.newConversationButton)
        create.performClick(nil)
        try await harness.waitUntil {
            harness.model.brainConversation.conversation.id != firstID && harness.focusedInput?.stringValue == ""
        }
        let secondID = harness.model.brainConversation.conversation.id
        #expect(harness.model.brainConversation.conversation.sessionID == nil)
        harness.type("Separate draft")
        await harness.settle()
        let picker = try #require(harness.conversationPicker)
        #expect(picker.numberOfItems == 2)
        picker.selectItem(at: 0)
        try #require(picker.sendAction(picker.action, to: picker.target))
        try await harness.waitUntil {
            harness.model.brainConversation.conversation.id == firstID && harness.focusedInput?.stringValue == "First draft"
        }
        picker.selectItem(at: 1)
        try #require(picker.sendAction(picker.action, to: picker.target))
        try await harness.waitUntil {
            harness.model.brainConversation.conversation.id == secondID && harness.focusedInput?.stringValue == "Separate draft"
        }
        #expect(harness.connections.made.isEmpty)
        #expect(editor.string == original)
        #expect(harness.model.isBrainConversationPresented)
    }

    @Test("selection stays available during work while Stop remains bound to the running conversation")
    func selectorDuringWork() async throws {
        let fixture = try PanelFixture()
        let harness = try await fixture.makeHarness()
        harness.model.isBrainConversationPresented = true
        try await harness.waitUntil { harness.focusedInput != nil }
        let firstID = harness.model.brainConversation.conversation.id
        harness.model.askBrainConversation("Running?")
        try await harness.waitUntil { harness.connections.made.first?.isPrompting == true }
        harness.connections.last.send(.event(.answerChunk("Partial")))
        try await harness.waitUntil { harness.model.brainConversation.conversation.turns.first?.answer == "Partial" }
        let create = try #require(harness.newConversationButton)
        #expect(create.isEnabled)
        create.performClick(nil)
        try await harness.waitUntil { harness.model.brainConversation.conversation.id != firstID }
        #expect(harness.conversationPicker?.isEnabled == true)
        #expect(harness.control(draft: "Q") == .stop(isEnabled: true))
        #expect(harness.model.brainConversation.conversation.turns.isEmpty)
        harness.model.stopBrainConversationTurn()
        try await harness.waitUntil { !harness.model.isAgentOperationActive }
        #expect(harness.control(draft: "Q") == .send(isEnabled: true))
        let first = try #require(harness.model.brainConversation.conversations.first { $0.id == firstID })
        #expect(first.turns.first?.state == .incomplete(reason: nil))
        #expect(first.turns.first?.answer == "Partial")
    }

    @Test(
        "clicking rendered sources keeps the panel and dirty editor text, even when the note is missing on disk",
        .disabled("Also exits the hosted suite early on main; tracked separately from native themes."),
        .bug("https://github.com/michalmar/notess/issues/152"),
        arguments: [false, true]
    )
    func sourceClicks(deleted: Bool) async throws {
        let fixture = try PanelFixture()
        let harness = try await fixture.makeHarness()
        let editor = try #require(harness.editor)
        let document = try #require(harness.model.document)
        let draft = "# Plan\n\n## Current\n\nUnsaved local answer.\n"
        editor.undoManager?.beginUndoGrouping()
        editor.insertText(draft, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        editor.undoManager?.endUndoGrouping()
        try await harness.waitUntil { document.text == draft }
        if deleted {
            try FileManager.default.removeItem(at: document.fileURL)
            document.reconcileWithDisk()
        }
        harness.model.isBrainConversationPresented = true
        try await harness.waitUntil { harness.input != nil }
        harness.model.askBrainConversation("Evidence?")
        try await harness.waitUntil { harness.connections.made.first?.isPrompting == true }
        harness.connections.last.send(.event(.answerChunk(
            "Brain Note: [[_brain/Alice]]. Original note fallback: [[Plan#Current]]."
        )))
        harness.connections.last.send(.finish(.endTurn))
        let brainURL = BrainConversationEvidence.noteURL(target: "_brain/Alice", section: nil)
        let planURL = BrainConversationEvidence.noteURL(target: "Plan", section: "Current")
        try await harness.waitUntil { harness.sourceButton(brainURL) != nil && harness.sourceButton(planURL) != nil }
        let brainButton = try #require(harness.sourceButton(brainURL))
        brainButton.performClick(nil)
        try await harness.waitUntil { harness.model.document?.displayName == "Alice" }
        #expect(harness.model.document?.isReadOnly == true)
        #expect(document.text == draft)
        #expect(document.hasUnsavedChanges)
        let planButton = try #require(harness.sourceButton(planURL))
        planButton.performClick(nil)
        try await harness.waitUntil { harness.model.document === document && harness.editor?.string == draft }
        #expect(harness.model.isBrainConversationPresented)
        #expect(harness.input != nil)
        #expect(harness.model.reveal?.range == NoteSection.find("Current", in: draft)?.headingRange)
        #expect(document.hasUnsavedChanges)
        #expect(harness.model.errorMessage == nil)
        if deleted {
            #expect(!FileManager.default.fileExists(atPath: document.fileURL.path))
        } else {
            #expect(try String(contentsOf: document.fileURL, encoding: .utf8) == "# Plan\n\nShip it.\n")
        }
    }

    @Test("the panel opens beside the note editor, which stays visible")
    func besideEditor() async throws {
        let fixture = try PanelFixture()
        let harness = try await fixture.makeHarness()
        let editor = try #require(harness.editor)
        #expect(harness.input == nil)

        harness.model.isBrainConversationPresented = true
        try await harness.waitUntil { harness.input != nil }

        let input = try #require(harness.input)
        let editorFrame = editor.enclosingScrollView.map { $0.convert($0.bounds, to: nil) } ?? editor.convert(editor.bounds, to: nil)
        let inputFrame = input.convert(input.bounds, to: nil)
        #expect(inputFrame.minX >= editorFrame.maxX, "the panel is to the right of the editor")
        #expect(editorFrame.width > 300, "the editor keeps its room")
        #expect(harness.editor === editor, "the open note stays in the editor")
    }

    @Test("opening focuses the question field; Return sends the question and leaves the note untouched")
    func inputFocus() async throws {
        let fixture = try PanelFixture()
        let harness = try await fixture.makeHarness()
        let editor = try #require(harness.editor)
        let original = editor.string

        harness.model.isBrainConversationPresented = true
        try await harness.waitUntil { harness.focusedInput != nil }

        harness.type("Who?")
        await harness.settle()
        #expect(harness.focusedInput?.stringValue == "Who?")
        harness.pressReturn()
        try await harness.waitUntil { harness.connections.made.first?.isPrompting == true }

        #expect(harness.connections.last.prompts.first?.last == "Who?")
        #expect(editor.string == original, "the editor got no keystrokes")
        #expect(harness.model.document?.hasUnsavedChanges == false)
        harness.connections.last.send(.finish(.endTurn))
        try await harness.waitUntil { !harness.model.isAgentOperationActive }
    }

    @Test("a running turn shows a spinner and Stop; a stopped turn says its answer is incomplete")
    func stopState() async throws {
        let fixture = try PanelFixture()
        let harness = try await fixture.makeHarness()
        harness.model.isBrainConversationPresented = true
        try await harness.waitUntil { harness.input != nil }
        #expect(!harness.isSpinnerShown)
        #expect(harness.control(draft: "Q") == .send(isEnabled: true))

        harness.model.askBrainConversation("Long?")
        try await harness.waitUntil { harness.connections.made.first?.isPrompting == true }
        harness.connections.last.send(.event(.answerChunk("Partial answer")))
        try await harness.waitUntil { harness.isSpinnerShown }
        #expect(harness.control(draft: "Q") == .stop(isEnabled: true))

        harness.model.stopBrainConversationTurn()
        #expect(harness.control(draft: "Q") == .stop(isEnabled: false))
        try await harness.waitUntil { !harness.isSpinnerShown }
        let turn = try #require(harness.model.brainConversation.conversation.turns.last)
        #expect(turn.answer == "Partial answer")
        #expect(BrainConversationTurnStatus.presentation(of: turn, at: Date()) == .incomplete("Neúplná odpověď: zastaveno"))
        #expect(harness.control(draft: "Q") == .send(isEnabled: true))
    }

    @Test("a failed turn shows its error, not an answer")
    func errorState() async throws {
        let fixture = try PanelFixture()
        let harness = try await fixture.makeHarness()
        harness.connections.startError = .sandbox(.ineffective)
        harness.model.isBrainConversationPresented = true
        try await harness.waitUntil { harness.input != nil }

        harness.model.askBrainConversation("Q")
        try await harness.waitUntil { !harness.model.brainConversation.isTurnActive }
        let turn = try #require(harness.model.brainConversation.conversation.turns.last)
        guard case .failed(let message) = BrainConversationTurnStatus.presentation(of: turn, at: Date()) else {
            Issue.record("expected an error, got \(turn.state)")
            return
        }
        #expect(message.contains("Agent nebyl spuštěn"))
        #expect(turn.answer.isEmpty)
        #expect(!harness.isSpinnerShown)
    }

    @Test("Send needs text and waits for a Brain Run; Stop is disabled while stopping")
    func controls() {
        var conversation = BrainConversation()
        #expect(BrainConversationPanel.control(for: conversation, isBrainRunActive: false, draft: " \n") == .send(isEnabled: false))
        #expect(BrainConversationPanel.control(for: conversation, isBrainRunActive: true, draft: "Q") == .send(isEnabled: false))
        #expect(BrainConversationPanel.control(for: conversation, isBrainRunActive: false, draft: "Q") == .send(isEnabled: true))
        let id = conversation.begin(question: "Q", at: Date(timeIntervalSince1970: 0))
        #expect(BrainConversationPanel.control(for: conversation, isBrainRunActive: false, draft: "Q") == .stop(isEnabled: true))
        if let id { conversation.markStopping(id) }
        #expect(BrainConversationPanel.control(for: conversation, isBrainRunActive: false, draft: "Q") == .stop(isEnabled: false))
    }

    @Test("the status shows elapsed time while running and never makes a partial or failed answer look done")
    func statusPresentation() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var conversation = BrainConversation()
        let runningBegun = conversation.begin(question: "Q", at: start)
        let running = try #require(runningBegun)
        #expect(BrainConversationTurnStatus.presentation(of: conversation.turns[0], at: start + 75) == .working("Agent pracuje… 1:15"))
        conversation.finish(running, stopReason: .endTurn, at: start + 3)
        #expect(BrainConversationTurnStatus.presentation(of: conversation.turns[0], at: start + 99) == .completed("Hotovo za 0:03"))

        let limitedBegun = conversation.begin(question: "Q2", at: start)
        let limited = try #require(limitedBegun)
        conversation.finish(limited, stopReason: .maxTokens, at: start + 5)
        guard case .incomplete(let text) = BrainConversationTurnStatus.presentation(of: conversation.turns[1], at: start + 5) else {
            Issue.record("expected incomplete")
            return
        }
        #expect(text.hasPrefix("Neúplná odpověď: "))

        let failingBegun = conversation.begin(question: "Q3", at: start)
        let failing = try #require(failingBegun)
        conversation.fail(failing, message: "Boom", at: start + 1)
        #expect(BrainConversationTurnStatus.presentation(of: conversation.turns[2], at: start + 1) == .failed("Boom"))
    }
}

@MainActor
private final class PanelHarness {
    let model: AppModel
    let connections: Connections
    let window: NSWindow
    let hostingView: NSHostingView<RootView>

    init(model: AppModel, connections: Connections) {
        self.model = model
        self.connections = connections
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        hostingView = NSHostingView(rootView: RootView(model: model, onCloseTab: { _ in }))
        hostingView.frame = window.contentLayoutRect
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
    }

    deinit {
        MainActor.assumeIsolated { window.close() }
    }

    var editor: MarkdownTextView? {
        subviews(of: hostingView).compactMap { $0 as? MarkdownTextView }.first
    }

    var input: NSTextField? {
        subviews(of: hostingView).compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == BrainConversationPanel.inputPlaceholder }
    }

    func sourceButton(_ url: URL) -> NSButton? {
        subviews(of: hostingView).compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "brain-source:\(url.absoluteString)" }
    }

    var newConversationButton: NSButton? {
        subviews(of: hostingView).compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "brain-conversation-new" }
    }

    var conversationPicker: NSPopUpButton? {
        subviews(of: hostingView).compactMap { $0 as? NSPopUpButton }
            .first { $0.identifier?.rawValue == "brain-conversation-picker" }
    }

    var scrollViews: [NSScrollView] {
        subviews(of: hostingView).compactMap { $0 as? NSScrollView }
    }

    func makeSettingsWindow() -> NSWindow {
        let settings = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 650),
            styleMask: [.titled, .resizable], backing: .buffered, defer: true
        )
        settings.isReleasedWhenClosed = false
        settings.contentView = NSHostingView(rootView: SettingsView(model: model))
        settings.makeKeyAndOrderFront(nil)
        return settings
    }

    func selectTheme(_ title: String, in settings: NSWindow) throws {
        let content = try #require(settings.contentView)
        let picker = try #require(subviews(of: content).compactMap { $0 as? NSPopUpButton }
            .first { $0.accessibilityLabel() == "Téma" })
        picker.selectItem(withTitle: title)
        try #require(picker.sendAction(picker.action, to: picker.target))
    }

    func renderedColor(at point: NSPoint, in view: NSView) -> NSColor? {
        hostingView.layoutSubtreeIfNeeded()
        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { return nil }
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        let local = hostingView.convert(point, from: view)
        let scale = CGFloat(rep.pixelsWide) / hostingView.bounds.width
        let y = hostingView.isFlipped ? local.y : hostingView.bounds.height - local.y
        return pixel(in: rep, x: Int(local.x * scale), y: Int(y * scale))
    }

    func panelPixelCount(hex: UInt32) throws -> Int {
        hostingView.layoutSubtreeIfNeeded()
        hostingView.display()
        let rep = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        if let directory = ProcessInfo.processInfo.environment["NOTESS_THEME_CAPTURE_DIR"] {
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appending(path: "brain-\(String(hex, radix: 16)).png"))
        }
        let input = try #require(input)
        let left = hostingView.convert(NSPoint(x: -10, y: 0), from: input).x
        let scale = CGFloat(rep.pixelsWide) / hostingView.bounds.width
        let expected = [CGFloat((hex >> 16) & 255), CGFloat((hex >> 8) & 255), CGFloat(hex & 255)].map { $0 / 255 }
        var count = 0
        for x in Int(left * scale)..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let color = pixel(in: rep, x: x, y: y) else { continue }
                if abs(color.redComponent - expected[0]) < 0.004
                    && abs(color.greenComponent - expected[1]) < 0.004
                    && abs(color.blueComponent - expected[2]) < 0.004 {
                    count += 1
                }
            }
        }
        return count
    }

    func capture(_ name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["NOTESS_THEME_CAPTURE_DIR"] else { return }
        hostingView.layoutSubtreeIfNeeded()
        let rep = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appending(path: "\(name).png"))
    }

    private func pixel(in rep: NSBitmapImageRep, x: Int, y: Int) -> NSColor? {
        guard let raw = rep.colorAt(x: x, y: y) else { return nil }
        // colorAt labels components as calibrated RGB even for a Display P3 bitmap.
        return NSColor(
            colorSpace: rep.colorSpace,
            components: [raw.redComponent, raw.greenComponent, raw.blueComponent, raw.alphaComponent],
            count: 4
        ).usingColorSpace(.sRGB)
    }

    /// The question field, when it holds keyboard focus.
    var focusedInput: NSTextField? {
        guard let fieldEditor = window.firstResponder as? NSTextView, fieldEditor.isFieldEditor,
              let field = fieldEditor.delegate as? NSTextField,
              field.placeholderString == BrainConversationPanel.inputPlaceholder
        else { return nil }
        return field
    }

    func control(draft: String) -> BrainConversationPanel.Control {
        BrainConversationPanel.control(
            for: model.brainConversation.activeConversation ?? model.brainConversation.conversation,
            isBrainRunActive: model.isBrainRunActive, draft: draft,
            isConnectionClosing: model.brainConversation.isConnectionClosing
        )
    }

    /// SwiftUI exposes no accessibility tree without an assistive client; a running
    /// turn's status is the only spinner in the window once indexing is done.
    var isSpinnerShown: Bool {
        subviews(of: hostingView).contains { view in
            guard let indicator = view as? NSProgressIndicator else { return false }
            return !indicator.isHiddenOrHasHiddenAncestor && indicator.window != nil && !indicator.visibleRect.isEmpty
        }
    }

    func type(_ text: String) {
        for character in text {
            send(String(character), keyCode: 0)
        }
    }

    func pressReturn() {
        send("\r", keyCode: 36)
    }

    private func send(_ characters: String, keyCode: UInt16) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        )
        if let event { window.sendEvent(event) }
    }

    /// Lets SwiftUI update and runs deferred focus changes queued on the main queue.
    func settle() async {
        for _ in 0..<3 {
            spinPanelRunLoop()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "timed out")
            await settle()
        }
    }

    private func subviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(subviews)
    }
}

private func spinPanelRunLoop() {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
}

private final class PanelFixture {
    let rootURL: URL
    private let defaultsSuiteName = "NotessConversationPanelTests-\(UUID().uuidString)"
    private let defaults: UserDefaults

    init(brainMarkdown: String = "# Alice\n\nKeeper.\n") throws {
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: "NotessConversationPanelTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL.appending(path: "_brain"), withIntermediateDirectories: true)
        try "# Plan\n\nShip it.\n".write(to: rootURL.appending(path: "Plan.md"), atomically: true, encoding: .utf8)
        try brainMarkdown.write(to: rootURL.appending(path: "_brain/Alice.md"), atomically: true, encoding: .utf8)
        defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: rootURL)
    }

    @MainActor
    func makeHarness() async throws -> PanelHarness {
        VaultLocationStore(defaults: defaults).remember(Vault(rootURL: rootURL))
        let settings = AppSettings(defaults: defaults)
        settings.copilotCLIPath = "/bin/sh"
        let connections = Connections()
        let model = AppModel(
            vaultLocationStore: VaultLocationStore(defaults: defaults),
            tabRestorationStore: TabRestorationStore(defaults: defaults),
            settings: settings,
            brainRunStateStore: BrainRunStateStore(
                directoryURL: rootURL.deletingLastPathComponent()
                    .appending(path: "\(rootURL.lastPathComponent)-state", directoryHint: .isDirectory)
            ),
            brainConversationConnection: connections.factory,
            brainConversationStore: BrainConversationStore(
                directoryURL: rootURL.deletingLastPathComponent()
                    .appending(path: "\(rootURL.lastPathComponent)-conversations", directoryHint: .isDirectory)
            ),
            now: Date.init
        )
        for document in model.tabSession.documents { model.closeTab(documentID: document.id) }
        _ = model.openExistingNote(relativePath: "Plan.md")
        let harness = PanelHarness(model: model, connections: connections)
        try await harness.waitUntil { harness.editor != nil && !model.isIndexing }
        await harness.settle()
        return harness
    }
}
