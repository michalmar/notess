import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Notess
@testable import NotessCore
@testable import NotessEditor

@MainActor
@Suite("Global search presentation", .serialized)
struct GlobalSearchPresentationTests {
    @Test("Command+Shift+F focuses the query at once, on every opening, so typing needs no click")
    func opensFocused() async throws {
        let fixture = try SearchPresentationFixture()
        try fixture.write("# Plán\n\n## Kickoff\nKickoff s klientem\n", to: "Notes/Plán.md")
        let harness = try await fixture.makeHarness()
        let editor = try #require(harness.editor)
        #expect(harness.window.firstResponder === editor)

        for _ in 0..<2 {
            harness.model.presentSearch()
            await harness.settle()
            #expect(harness.searchField != nil, "the query field has keyboard focus")

            harness.type("kick")
            await harness.settle()
            let search = try #require(harness.model.globalSearch)
            #expect(search.query == "kick")
            try await harness.waitUntil { !search.results.isEmpty }
            #expect(search.results.map(\.relativePath) == ["Notes/Plán.md"])
            #expect(editor.string == "# Plán\n\n## Kickoff\nKickoff s klientem\n", "the editor got no keystrokes")

            harness.model.isSearchPresented = false
            await harness.settle()
            #expect(harness.window.firstResponder === editor, "closing returns focus to the editor")
        }
    }

    @Test("each opening starts on All, whatever scope was chosen before, and scope changes update results")
    func scopeResetsToAll() async throws {
        let fixture = try SearchPresentationFixture()
        try fixture.write("## Porada\nklient\n", to: "Journal/2026/03/2026-03-14.md")
        try fixture.write("## Fakta\nklient\n", to: "_brain/companies/Acme.md")
        let harness = try await fixture.makeHarness()

        harness.model.presentSearch()
        await harness.settle()
        let first = try #require(harness.model.globalSearch)
        #expect(first.scope == .all)
        harness.type("klient")
        try await harness.waitUntil { first.results.count == 2 }

        first.scope = .brain
        #expect(first.results.isEmpty && first.selectedResult == nil, "the previous scope's results cannot be opened")
        try await harness.waitUntil { first.results.map(\.kind) == [.brainNote] }
        first.scope = .notes
        try await harness.waitUntil { first.groups.isEmpty }

        harness.model.isSearchPresented = false
        await harness.settle()
        harness.model.presentSearch()
        await harness.settle()
        let second = try #require(harness.model.globalSearch)
        #expect(second !== first)
        #expect(second.scope == .all)
        #expect(second.query.isEmpty)
        #expect(harness.searchField != nil)
    }

    @Test("global search finds saved text only: an unsaved edit is found after it is saved")
    func savedContentOnly() async throws {
        let fixture = try SearchPresentationFixture()
        try fixture.write("# Plán\n\nstaré\n", to: "Notes/Plán.md")
        let harness = try await fixture.makeHarness()
        let document = try #require(harness.model.document)
        document.text = "# Plán\n\nnovinka\n"

        harness.model.presentSearch()
        await harness.settle()
        let search = try #require(harness.model.globalSearch)
        harness.type("novinka")
        try await harness.waitUntil { !search.isSearching && search.query == "novinka" }
        #expect(search.results.isEmpty)
        harness.model.isSearchPresented = false

        let revision = harness.model.searchIndexRevision
        #expect(harness.model.save(documentID: document.id))
        try await harness.waitUntil { harness.model.searchIndexRevision > revision }
        harness.model.presentSearch()
        await harness.settle()
        let after = try #require(harness.model.globalSearch)
        harness.type("novinka")
        try await harness.waitUntil { after.results.map(\.relativePath) == ["Notes/Plán.md"] }
    }

    @Test("a note with several matching Sections is one row with a matching preview; Enter opens its dirty tab at the first match")
    func fileResultsOpenAtFirstMatch() async throws {
        let fixture = try SearchPresentationFixture()
        let saved = "# Plán\n\nÚvod bez shody\n\n## Kickoff\nKickoff s klientem\n\n## Retro\nkickoff znovu\n"
        try fixture.write(saved, to: "Notes/Plán.md")
        try fixture.write("## Jinde\nTaky kickoff\n", to: "Notes/Jiný.md")
        let harness = try await fixture.makeHarness()
        let editor = try #require(harness.editor)
        let document = try #require(harness.model.document)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("Neuložený řádek\n", replacementRange: NSRange(location: 0, length: 0))
        let dirtyText = "Neuložený řádek\n" + saved
        #expect(document.text == dirtyText)
        #expect(document.hasUnsavedChanges)

        let tablesBeforeSearch = Set(harness.tables.map(ObjectIdentifier.init))
        harness.model.presentSearch()
        await harness.settle()
        harness.type("kickoff")
        let search = try #require(harness.model.globalSearch)
        try await harness.waitUntil { search.results.count == 2 && !search.isSearching }
        #expect(Set(search.results.map(\.relativePath)) == ["Notes/Plán.md", "Notes/Jiný.md"])
        let plan = try #require(search.results.first { $0.relativePath == "Notes/Plán.md" })
        #expect(plan.matchingOrdinals.count == 2)
        #expect(plan.title == "Kickoff")
        #expect((plan.highlightedTitle.parts + plan.snippet.parts).contains { $0.isMatch && $0.text.lowercased() == "kickoff" })
        await harness.settle()
        let list = try #require(harness.tables.first { !tablesBeforeSearch.contains(ObjectIdentifier($0)) })
        #expect(list.numberOfRows == search.groups.count + search.results.count, "one header and one row per note")

        search.selection = plan.id
        await harness.settle()
        harness.pressReturn()
        try await harness.waitUntil { harness.model.globalSearch == nil && harness.window.firstResponder === editor }
        await harness.settle()

        #expect(harness.model.document === document)
        #expect(document.text == dirtyText, "unsaved text is kept")
        #expect(editor.string == dirtyText)
        let firstMatch = (dirtyText as NSString).range(of: "Kickoff")
        #expect(editor.selectedRange() == NSRange(location: firstMatch.location, length: 0))
    }

    @Test("while the index is being built, the open search says its results may be incomplete, also above results")
    func indexingStatus() async throws {
        let fixture = try SearchPresentationFixture()
        try fixture.write("# Plán\n\n## Kickoff\nKickoff s klientem\n", to: "Notes/Plán.md")
        let harness = try await fixture.makeHarness()
        harness.model.presentSearch()
        await harness.settle()
        let search = try #require(harness.model.globalSearch)
        #expect(!harness.indexingStatusIsShown)

        harness.type("kickoff")
        try await harness.waitUntil { !search.isSearching && !search.results.isEmpty }
        harness.model.isIndexing = true
        await harness.settle()
        #expect(harness.indexingStatusIsShown, "results found so far are shown with the status")

        harness.type("x")
        try await harness.waitUntil { !search.isSearching && search.query == "kickoffx" }
        #expect(search.results.isEmpty)
        #expect(harness.indexingStatusIsShown, "no results yet is not presented as an empty search")

        harness.model.isIndexing = false
        await harness.settle()
        #expect(!harness.indexingStatusIsShown)
    }
}

@MainActor
final class SearchPresentationHarness {
    let model: AppModel
    let window: NSWindow
    let hostingView: NSHostingView<RootView>

    init(model: AppModel) {
        self.model = model
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700),
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

    var editor: MarkdownTextView? {
        allSubviews(of: hostingView).compactMap { $0 as? MarkdownTextView }.first
    }

    /// The global search query field, when it holds keyboard focus.
    var searchField: NSTextField? {
        guard let fieldEditor = window.firstResponder as? NSTextView, fieldEditor.isFieldEditor,
              let field = fieldEditor.delegate as? NSTextField,
              field.placeholderString?.hasPrefix("Hledat v uložených") == true
        else { return nil }
        return field
    }

    /// Types into whatever has keyboard focus, as real key presses do.
    func type(_ text: String) {
        for character in text {
            let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: String(character),
                charactersIgnoringModifiers: String(character),
                isARepeat: false,
                keyCode: 0
            )
            if let event { window.sendEvent(event) }
        }
    }

    /// The tables shown, such as the sidebar and the search result list.
    var tables: [NSTableView] {
        allSubviews(of: hostingView).compactMap { $0 as? NSTableView }
    }

    func pressReturn() {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        )
        if let event { window.sendEvent(event) }
    }

    /// Lets SwiftUI update and runs deferred focus changes queued on the main queue.
    func settle() async {
        for _ in 0..<3 {
            spinRunLoop()
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

    deinit {
        MainActor.assumeIsolated { window.close() }
    }
}

@MainActor
private func spinRunLoop() {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
}

@MainActor
private func allSubviews(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(allSubviews)
}

/// A temporary Vault with isolated settings for hosting the app's root view.
final class SearchPresentationFixture {
    let rootURL: URL
    private let defaultsSuiteName: String
    private let defaults: UserDefaults

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: "NotessSearchUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defaultsSuiteName = "NotessSearchUITests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: rootURL)
    }

    func write(_ text: String, to relativePath: String) throws {
        let url = rootURL.appending(path: relativePath, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The app on this Vault with an indexed Vault and, when given, that note open in the editor.
    @MainActor
    func makeHarness(opening relativePath: String? = "Notes/Plán.md") async throws -> SearchPresentationHarness {
        VaultLocationStore(defaults: defaults).remember(Vault(rootURL: rootURL))
        let model = AppModel(
            vaultLocationStore: VaultLocationStore(defaults: defaults),
            tabRestorationStore: TabRestorationStore(defaults: defaults),
            settings: AppSettings(defaults: defaults),
            brainRunStateStore: BrainRunStateStore(
                directoryURL: rootURL.appending(path: ".test-brain-runs", directoryHint: .isDirectory)
            ),
            now: { Date(timeIntervalSince1970: 1_760_765_000) }
        )
        if let relativePath, FileManager.default.fileExists(atPath: rootURL.appending(path: relativePath).path) {
            for document in model.tabSession.documents { model.closeTab(documentID: document.id) }
            _ = model.openExistingNote(relativePath: relativePath)
        }
        let harness = SearchPresentationHarness(model: model)
        try await harness.waitUntil { !model.isIndexing }
        await harness.settle()
        return harness
    }
}

