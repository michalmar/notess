import Foundation
import SwiftUI
import Testing
@testable import Notess
@testable import NotessCore

@MainActor
@Suite("Opening notes through the app")
struct AppModelOpenNoteTests {
    @Test("sidebar opening reuses a dirty tab when its file becomes invalid UTF-8")
    func sidebarReusesInvalidUTF8Tab() throws {
        let fixture = try AppModelFixture()
        try fixture.write("# Idea\n", to: "Notes/Idea.md")
        let model = fixture.makeModel()
        let document = try #require(model.openExistingNote(relativePath: "Notes/Idea.md"))
        let attachmentData = Data("image".utf8)
        let attachment = document.stageAttachment(data: attachmentData, fileExtension: "png")
        document.text = "# Unsaved\n\(attachment.markdown)"
        try Data([0xFF]).write(to: document.fileURL)

        model.openNote(relativePath: "Notes/Idea.md")

        #expect(model.document === document)
        #expect(document.text == "# Unsaved\n\(attachment.markdown)")
        #expect(document.stagedAttachmentData(relativePath: attachment.relativePath) == attachmentData)
        #expect(model.errorMessage == nil)
    }

    @Test("navigation routes reuse a deleted tab and reveal its in-memory Section")
    func navigationRoutesReuseDeletedTab() throws {
        let fixture = try AppModelFixture()
        try fixture.write("# Idea\n\n## Saved\n", to: "Notes/Idea.md")
        try fixture.write("# Other\n", to: "Notes/Other.md")
        let model = fixture.makeModel()
        let document = try #require(model.openExistingNote(relativePath: "Notes/Idea.md"))
        document.text = "# Idea\n\n## Current\n\nLocal text\n"
        try FileManager.default.removeItem(at: document.fileURL)
        document.reconcileWithDisk()
        _ = model.openExistingNote(relativePath: "Notes/Other.md")

        model.openWikiLink(WikiLink(
            target: "Idea",
            section: "Current",
            range: NSRange(location: 0, length: 0)
        ))
        #expect(model.document === document)
        #expect(model.reveal?.documentID == AnyHashable(document.id))

        _ = model.openExistingNote(relativePath: "Notes/Other.md")
        model.openSearchResult(SearchResult(
            relativePath: "Notes/Idea.md",
            kind: .freeNote,
            ordinal: 1,
            title: "Current",
            highlightedTitle: SearchSnippet(text: "Current", highlighting: "Current"),
            snippet: SearchSnippet(text: "Local text", highlighting: "Local"),
            matchingOrdinals: [1],
            query: SearchQuery("local")
        ))
        #expect(model.document === document)
        #expect(model.reveal?.documentID == AnyHashable(document.id))
        #expect(model.reveal?.range == (document.text as NSString).range(of: "Local"))

        _ = model.openExistingNote(relativePath: "Notes/Other.md")
        model.openTimelineSection(TagTimelineSection(
            relativePath: "Notes/Idea.md",
            ordinal: 1,
            title: "Current",
            markdown: "## Current\n\nSaved text\n"
        ))
        #expect(model.document === document)
        #expect(model.reveal?.documentID == AnyHashable(document.id))
        #expect(model.errorMessage == nil)

        _ = model.openExistingNote(relativePath: "Notes/Other.md")
        model.openBacklink(Backlink(
            sourceRelativePath: "Notes/Idea.md",
            sectionTitle: "Current",
            sectionTitleOccurrence: 0,
            preview: "Local text",
            sectionHeadingRange: NSRange(location: 8, length: 10)
        ))
        #expect(model.document === document)
        #expect(model.reveal?.documentID == AnyHashable(document.id))
        #expect(model.errorMessage == nil)
    }

    @Test("the Tag suggestion source follows the index: a save refreshes its revision and vocabulary, another Vault replaces it")
    func tagSuggestionSourceFollowsIndex() async throws {
        let fixture = try AppModelFixture()
        try fixture.write("## Old #stary\n", to: "Notes/Old.md")
        let model = fixture.makeModel()
        let first = try #require(model.tagSuggestionSource)
        try await waitForIndexing(model)
        let settled = try #require(model.tagSuggestionSource)
        #expect(settled.id == first.id)
        #expect(try await settled.suggestions("s") == ["stary"])
        #expect(try await settled.suggestions("n").isEmpty)

        // An unsaved addition is not offered; the save is, and bumps the revision.
        let document = try #require(model.openExistingNote(relativePath: "Notes/Old.md"))
        document.text = "## Old #stary #novy\n"
        #expect(try await settled.suggestions("n").isEmpty)
        let revision = model.searchIndexRevision
        #expect(model.save(documentID: document.id))
        try await waitUntil { model.searchIndexRevision > revision }
        let refreshed = try #require(model.tagSuggestionSource)
        #expect(refreshed.id == settled.id)
        #expect(refreshed.revision > settled.revision)
        #expect(try await refreshed.suggestions("n") == ["novy"])

        // Another Vault is another vocabulary: a new identity with only its own Tags.
        let other = try AppModelFixture()
        try other.write("## Other #cizi\n", to: "Notes/Other.md")
        model.chooseVault(at: other.rootURL)
        let switched = try #require(model.tagSuggestionSource)
        #expect(switched.id != refreshed.id)
        try await waitForIndexing(model)
        let switchedSettled = try #require(model.tagSuggestionSource)
        #expect(switchedSettled.id == switched.id)
        #expect(try await switchedSettled.suggestions("c") == ["cizi"])
        #expect(try await switchedSettled.suggestions("s").isEmpty)
    }

    @Test("heading-only timeline Wiki-links use their source Daily Entry and reuse unsaved text", arguments: [false, true])
    func timelineHeadingLinkUsesSource(deletedOnDisk: Bool) throws {
        let fixture = try AppModelFixture()
        let path = "Journal/2026/10/2026-10-15.md"
        let saved = "# 2026-10-15\n\n## Decisions\n\nSaved text\n"
        try fixture.write(saved, to: path)
        try fixture.write("# Other\n\n## Decisions\n", to: "Notes/Other.md")
        let model = fixture.makeModel()
        let source = try #require(model.openExistingNote(relativePath: path))
        source.text = "# 2026-10-15\n\n## Decisions\n\nUnsaved text\n"
        if deletedOnDisk {
            try FileManager.default.removeItem(at: source.fileURL)
            source.reconcileWithDisk()
        }
        let other = try #require(model.openExistingNote(relativePath: "Notes/Other.md"))
        model.sidebarMode = .tags
        let link = try #require(WikiLink.links(in: "[[#Decisions]]").first)

        model.openWikiLink(link, sourceRelativePath: path)

        #expect(model.document === source)
        #expect(model.document !== other)
        #expect(model.sidebarMode == .journal)
        #expect(model.reveal?.documentID == AnyHashable(source.id))
        #expect(model.reveal?.range == NoteSection.find("Decisions", in: source.text)?.headingRange)
        #expect(source.hasUnsavedChanges)
        #expect(source.text.contains("Unsaved text"))
        #expect(model.errorMessage == nil)
        if deletedOnDisk {
            #expect(FileManager.default.fileExists(atPath: source.fileURL.path) == false)
        } else {
            #expect(try String(contentsOf: source.fileURL, encoding: .utf8) == saved)
        }
    }

    @Test("named timeline Wiki-links open their target rather than the card's source")
    func timelineNamedLinkUsesTarget() throws {
        let fixture = try AppModelFixture()
        try fixture.write("# Idea\n\n## Decisions\n", to: "Notes/Idea.md")
        let model = fixture.makeModel()
        let target = try #require(model.openExistingNote(relativePath: "Notes/Idea.md"))
        model.sidebarMode = .tags

        model.openWikiLink(
            try #require(WikiLink.links(in: "[[Idea#Decisions]]").first),
            sourceRelativePath: "Journal/2026/10/2026-10-15.md"
        )

        #expect(model.document === target)
        #expect(model.sidebarMode == .journal)
        #expect(model.reveal?.range == NoteSection.find("Decisions", in: target.text)?.headingRange)
        #expect(model.errorMessage == nil)
    }

    @Test("missing timeline Wiki-link notes and headings report errors without creating files")
    func missingTimelineLinkTargets() throws {
        let fixture = try AppModelFixture()
        let path = "Journal/2026/10/2026-10-15.md"
        let saved = "# 2026-10-15\n\n## Decisions\n"
        try fixture.write(saved, to: path)
        let model = fixture.makeModel()
        model.sidebarMode = .tags

        model.openWikiLink(
            try #require(WikiLink.links(in: "[[#Decisions]]").first),
            sourceRelativePath: "Journal/2026/10/2026-10-14.md"
        )
        #expect(model.errorMessage == "Zdrojová poznámka už ve Vaultu neexistuje.")
        #expect(model.sidebarMode == .tags)
        #expect(FileManager.default.fileExists(atPath: fixture.rootURL.appending(path: "Journal/2026/10/2026-10-14.md").path) == false)

        model.openWikiLink(
            try #require(WikiLink.links(in: "[[Missing]]").first),
            sourceRelativePath: path
        )
        #expect(model.errorMessage == "Poznámka „Missing“ ve Vaultu neexistuje.")
        #expect(model.sidebarMode == .tags)

        model.openWikiLink(
            try #require(WikiLink.links(in: "[[#Missing]]").first),
            sourceRelativePath: path
        )
        #expect(model.errorMessage == "Sekce „Missing“ v poznámce „2026-10-15“ neexistuje.")
        #expect(model.document?.fileURL == fixture.rootURL.appending(path: path))
        #expect(model.reveal == nil)
        #expect(try String(contentsOf: fixture.rootURL.appending(path: path), encoding: .utf8) == saved)
    }

    private func waitForIndexing(_ model: AppModel) async throws {
        try await waitUntil { !model.isIndexing }
    }

    /// Polls until `condition` holds, failing after a generous deadline.
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class AppModelFixture {
    let rootURL: URL
    private let defaultsSuiteName: String
    private let defaults: UserDefaults

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: "NotessAppTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defaultsSuiteName = "NotessAppTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: rootURL)
    }

    func write(_ text: String, to relativePath: String) throws {
        let url = rootURL.appending(path: relativePath, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @MainActor
    func makeModel() -> AppModel {
        let vault = Vault(rootURL: rootURL)
        VaultLocationStore(defaults: defaults).remember(vault)
        return AppModel(
            vaultLocationStore: VaultLocationStore(defaults: defaults),
            tabRestorationStore: TabRestorationStore(defaults: defaults),
            settings: AppSettings(defaults: defaults),
            brainRunStateStore: BrainRunStateStore(
                directoryURL: rootURL.appending(path: ".test-brain-runs", directoryHint: .isDirectory)
            ),
            tagGroupStore: TagGroupStore(
                directoryURL: rootURL.appending(path: ".test-tag-groups", directoryHint: .isDirectory)
            ),
            now: { Date(timeIntervalSince1970: 1_760_765_000) }
        )
    }
}

@MainActor
@Suite("Search commands")
struct SearchCommandTests {
    @Test("Command+F and Command+Shift+F are different shortcuts")
    func distinctShortcuts() {
        #expect(SearchCommand.findInNote.modifiers == .command)
        #expect(SearchCommand.globalSearch.modifiers == [.command, .shift])
        #expect(SearchCommand.findInNote.key == SearchCommand.globalSearch.key)
        #expect(SearchCommand.findInNote.modifiers != SearchCommand.globalSearch.modifiers)
    }

    @Test("global search opens the search window; find in note does not")
    func routing() throws {
        let fixture = try AppModelFixture()
        let model = fixture.makeModel()
        #expect(model.isSearchPresented == false)

        var editorFindShown = 0
        SearchCommand.findInNote.perform(on: model) { editorFindShown += 1 }
        #expect(model.isSearchPresented == false)
        #expect(editorFindShown == 1)

        SearchCommand.globalSearch.perform(on: model) { editorFindShown += 1 }
        #expect(model.isSearchPresented)
        #expect(editorFindShown == 1)
    }
}
