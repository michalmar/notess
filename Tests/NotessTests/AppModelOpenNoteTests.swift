import Foundation
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
            snippet: SearchSnippet(text: "Local text", highlighting: "Local")
        ))
        #expect(model.document === document)
        #expect(model.reveal?.documentID == AnyHashable(document.id))

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
            now: { Date(timeIntervalSince1970: 1_760_765_000) }
        )
    }
}
