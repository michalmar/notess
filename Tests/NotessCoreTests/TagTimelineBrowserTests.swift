import Foundation
import Testing
@testable import NotessCore

@MainActor
@Suite("Tag Timeline browsing")
final class TagTimelineBrowserTests {
    private let vault: TemporaryVault
    private let databaseURL: URL

    init() throws {
        vault = try TemporaryVault()
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotessTimelineTests-\(UUID().uuidString)")
            .appendingPathComponent("index.sqlite")
        try vault.write("# 2026-06-02\n\n## Porada #acme\nzápis\n\n## Jiné #beta\nb\n", to: "Journal/2026/06/2026-06-02.md")
        try vault.write("# 2026-06-01\n\n## Start #ACME\nstart\n", to: "Journal/2026/06/2026-06-01.md")
        try vault.write("## Volná #volna\nx\n", to: "Projekty/Volná.md")
    }

    deinit {
        try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
    }

    private func makeIndex() async throws -> SearchIndex {
        let index = SearchIndex(vault: vault.vault, databaseURL: databaseURL)
        try await index.synchronize()
        return index
    }

    private func sectionIDs(_ browser: TagTimelineBrowser) -> [String]? {
        guard case .loaded(let days)? = browser.timeline else { return nil }
        return days.flatMap { $0.sections.map(\.id) }
    }

    @Test("Tags load from saved Daily Entries; nothing is selected until the reader picks a Tag")
    func loadsTags() async throws {
        let browser = TagTimelineBrowser()
        #expect(browser.tags == .loading)
        browser.connect(try await makeIndex())
        #expect(browser.tags == .loading)
        await browser.refresh()
        #expect(browser.tags == .loaded(["acme", "beta"]))
        #expect(browser.selectedTag == nil)
        #expect(browser.timeline == nil)
    }

    @Test("selecting a Tag loads its timeline; selecting another replaces it")
    func selectsOneTag() async throws {
        let browser = TagTimelineBrowser()
        browser.connect(try await makeIndex())
        await browser.refresh()

        await browser.select("acme")
        #expect(browser.selectedTag == "acme")
        #expect(sectionIDs(browser) == ["Journal/2026/06/2026-06-02.md#1", "Journal/2026/06/2026-06-01.md#1"])

        await browser.select("beta")
        #expect(sectionIDs(browser) == ["Journal/2026/06/2026-06-02.md#2"])

        await browser.select(nil)
        #expect(browser.timeline == nil)
    }

    @Test("an older, slower answer never overwrites the timeline of the Tag selected last")
    func staleCompletionsAreIgnored() async throws {
        let browser = TagTimelineBrowser()
        browser.connect(try await makeIndex())
        await browser.refresh()
        let first = Task { await browser.select("acme") }
        while browser.selectedTag != "acme" { await Task.yield() }
        let refresh = Task { await browser.refresh() }
        await browser.select("beta")
        await first.value
        await refresh.value
        #expect(browser.selectedTag == "beta")
        #expect(sectionIDs(browser) == ["Journal/2026/06/2026-06-02.md#2"])
        #expect(browser.tags == .loaded(["acme", "beta"]))
    }

    @Test("a refresh after a save shows the saved Tags and Sections; a Tag that disappeared leaves an empty timeline")
    func refreshFollowsSaves() async throws {
        let index = try await makeIndex()
        let browser = TagTimelineBrowser()
        browser.connect(index)
        await browser.refresh()
        await browser.select("beta")

        let url = vault.vault.rootURL.appending(path: "Journal/2026/06/2026-06-02.md")
        let document = try NoteDocument.open(fileURL: url, newFileContent: "")
        document.text = "# 2026-06-02\n\n## Porada #acme #gama\nzápis\n"
        await browser.refresh()
        #expect(browser.tags == .loaded(["acme", "beta"]))
        #expect(sectionIDs(browser) == ["Journal/2026/06/2026-06-02.md#2"])

        try document.save()
        try await index.update(fileAt: url)
        await browser.refresh()
        #expect(browser.tags == .loaded(["acme", "gama"]))
        #expect(browser.selectedTag == "beta")
        #expect(sectionIDs(browser) == [])
    }

    @Test("connecting another index starts over and drops answers from the previous one")
    func reconnecting() async throws {
        let browser = TagTimelineBrowser()
        browser.connect(try await makeIndex())
        await browser.refresh()
        await browser.select("acme")

        let emptyVault = try TemporaryVault()
        let emptyIndex = SearchIndex(
            vault: emptyVault.vault,
            databaseURL: databaseURL.deletingLastPathComponent().appendingPathComponent("other.sqlite")
        )
        try await emptyIndex.synchronize()
        browser.connect(emptyIndex)
        #expect(browser.selectedTag == nil)
        #expect(browser.timeline == nil)
        #expect(browser.tags == .loading)
        await browser.refresh()
        #expect(browser.tags == .loaded([]))
    }

    @Test("a failing index is reported as a failure, not as an empty list or timeline")
    func failures() async throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("NotessBlocker-\(UUID().uuidString)")
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let broken = SearchIndex(vault: vault.vault, databaseURL: blocker.appendingPathComponent("index.sqlite"))

        let browser = TagTimelineBrowser()
        browser.connect(broken)
        await browser.refresh()
        guard case .failed(let message) = browser.tags else {
            Issue.record("expected a failure, got \(browser.tags)")
            return
        }
        #expect(!message.isEmpty)

        await browser.select("acme")
        guard case .failed? = browser.timeline else {
            Issue.record("expected a failure, got \(String(describing: browser.timeline))")
            return
        }
    }

    @Test("a failed index update keeps the shown Tags and timeline, and recovery refreshes them")
    func failedUpdateKeepsTimeline() async throws {
        let index = try await makeIndex()
        let browser = TagTimelineBrowser()
        browser.connect(index)
        await browser.refresh()
        await browser.select("acme")
        let before = sectionIDs(browser)

        let path = "Journal/2026/06/2026-06-02.md"
        try Data([0x23, 0xFF, 0xFE]).write(to: vault.vault.rootURL.appending(path: path))
        await #expect(throws: SearchIndex.IndexingFailure.self) { try await index.update(relativePaths: [path]) }
        await browser.refresh()
        #expect(browser.tags == .loaded(["acme", "beta"]))
        #expect(sectionIDs(browser) == before)

        try vault.write("# 2026-06-02\n\n## Porada #gama\nzápis\n", to: path)
        try await index.synchronize()
        await browser.refresh()
        #expect(browser.tags == .loaded(["acme", "gama"]))
        #expect(sectionIDs(browser) == ["Journal/2026/06/2026-06-01.md#1"])
    }
}
