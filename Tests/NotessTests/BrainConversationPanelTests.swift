import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Notess
@testable import NotessCore
@testable import NotessEditor

@MainActor
@Suite("Brain Conversation panel", .serialized)
struct BrainConversationPanelTests {
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
            for: model.brainConversation.conversation, isBrainRunActive: model.isBrainRunActive, draft: draft
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

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: "NotessConversationPanelTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL.appending(path: "_brain"), withIntermediateDirectories: true)
        try "# Plan\n\nShip it.\n".write(to: rootURL.appending(path: "Plan.md"), atomically: true, encoding: .utf8)
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
