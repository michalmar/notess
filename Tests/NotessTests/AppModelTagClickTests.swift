import Foundation
import Testing
@testable import Notess
@testable import NotessCore

@MainActor
@Suite("Opening a Tag Timeline by clicking a Tag")
struct AppModelTagClickTests {
    @Test("a clicked Tag switches to Tags mode, selects the normalised Tag and loads saved Daily Entries only")
    func opensTimeline() async throws {
        let fixture = try TagGroupFixture()
        try fixture.write("# 2026-06-02\n\n## Porada #Acme\nzápis\n", to: "Journal/2026/06/2026-06-02.md")
        try fixture.write("## Volná #acme\nx\n", to: "Notes/Volná.md")
        try fixture.write("## Fakt #acme\n", to: "_brain/Lidé/Acme.md")
        let model = fixture.makeModel()
        try await fixture.settle(model)
        #expect(model.sidebarMode == .journal)

        model.openTagTimeline("ACME")

        #expect(model.sidebarMode == .tags)
        try await waitForTimeline(model)
        #expect(model.tagTimeline.selectedTag == "acme")
        guard case .loaded(let days)? = model.tagTimeline.timeline else { return }
        #expect(days.flatMap { $0.sections.map(\.relativePath) } == ["Journal/2026/06/2026-06-02.md"])
    }

    @Test("#Acme, #ACME and #acme open the same Tag Timeline")
    func normalises() async throws {
        let fixture = try TagGroupFixture()
        try fixture.write("# 2026-06-02\n\n## Porada #acme\n", to: "Journal/2026/06/2026-06-02.md")
        let model = fixture.makeModel()
        try await fixture.settle(model)

        for name in ["Acme", "#ACME", "acme"] {
            model.openTagTimeline(name)
            try await waitForTimeline(model)
            #expect(model.tagTimeline.selectedTag == "acme")
        }
    }

    @Test("an unsaved open note stays open, active and unsaved, nothing is written, and Journal shows it again")
    func keepsUnsavedNote() async throws {
        let fixture = try TagGroupFixture()
        let saved = "# 2026-06-02\n\n## Porada #acme\n"
        try fixture.write(saved, to: "Journal/2026/06/2026-06-02.md")
        let model = fixture.makeModel()
        try await fixture.settle(model)
        let document = try #require(model.openNote(
            at: fixture.rootURL.appending(path: "Journal/2026/06/2026-06-02.md", directoryHint: .notDirectory)
        ))
        document.text = saved + "neuloženo #acme #jen-tady\n"
        let documentIDs = model.tabSession.documents.map(\.id)

        model.openTagTimeline("acme")
        try await waitForTimeline(model)

        #expect(model.tabSession.documents.map(\.id) == documentIDs)
        #expect(model.document?.id == document.id)
        #expect(document.hasUnsavedChanges)
        #expect(try fixture.read("Journal/2026/06/2026-06-02.md") == saved)

        model.sidebarMode = .journal
        #expect(model.document?.id == document.id)
        #expect(document.text == saved + "neuloženo #acme #jen-tady\n")
    }

    @Test("a Tag only in unsaved text or Free Notes is selected with an empty timeline")
    func tagWithoutSavedSections() async throws {
        let fixture = try TagGroupFixture()
        try fixture.write("# 2026-06-02\n\n## Porada #acme\n", to: "Journal/2026/06/2026-06-02.md")
        try fixture.write("## Volná #volna\n", to: "Notes/Volná.md")
        let model = fixture.makeModel()
        try await fixture.settle(model)

        for tag in ["volna", "jen-tady"] {
            model.openTagTimeline(tag)
            try await waitForTimeline(model, of: tag)
            #expect(model.tagTimeline.selectedTag == tag)
            #expect(model.tagTimeline.timeline == .loaded([]))
        }
    }

    @Test("works from today's in-memory Daily Entry that has no file yet, without writing it")
    func inMemoryDailyEntry() async throws {
        let fixture = try TagGroupFixture()
        try fixture.write("# 2026-06-02\n\n## Porada #acme\n", to: "Journal/2026/06/2026-06-02.md")
        let model = fixture.makeModel()
        try await fixture.settle(model)
        let today = try #require(model.document)
        #expect(today.existsOnDisk == false)
        today.text += "\n## Dnes #acme\n"

        model.openTagTimeline("acme")
        try await waitForTimeline(model)

        #expect(model.tagTimeline.selectedTag == "acme")
        #expect(model.document?.id == today.id)
        #expect(today.existsOnDisk == false)
        #expect(!FileManager.default.fileExists(atPath: today.fileURL.path))
    }

    @Test("in Tags mode a clicked Tag switches the timeline; the Tag already shown stays without reloading")
    func fromTagTimeline() async throws {
        let fixture = try TagGroupFixture()
        try fixture.write("# 2026-06-02\n\n## Porada #acme #beta\n", to: "Journal/2026/06/2026-06-02.md")
        let model = fixture.makeModel()
        try await fixture.settle(model)
        model.openTagTimeline("acme")
        try await waitForTimeline(model)

        model.openTagTimeline("Beta")
        #expect(model.sidebarMode == .tags)
        try await waitForTimeline(model, of: "beta")
        let shown = model.tagTimeline.timeline

        let changed = ChangeFlag()
        withObservationTracking {
            _ = model.tagTimeline.timeline
            _ = model.tagTimeline.selectedTag
            _ = model.tagTimeline.tags
        } onChange: { changed.set() }
        model.openTagTimeline("#beta")
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))

        #expect(!changed.isSet)
        #expect(model.tagTimeline.selectedTag == "beta")
        #expect(model.tagTimeline.timeline == shown)
    }

    /// Waits until the timeline of `tag` has loaded.
    private func waitForTimeline(_ model: AppModel, of tag: String = "acme") async throws {
        try await waitUntil {
            guard model.tagTimeline.selectedTag == tag else { return false }
            if case .loaded? = model.tagTimeline.timeline { return true }
            return false
        }
    }
}

private final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
