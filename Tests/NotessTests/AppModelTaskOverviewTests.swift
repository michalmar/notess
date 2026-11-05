import Foundation
import NotessEditor
import Testing
@testable import Notess
@testable import NotessCore

@MainActor
@Suite("Browsing saved Tasks and opening their source notes")
struct AppModelTaskOverviewTests {
    private static let plan = "Projekty/Plán.md"
    private static let day = "Journal/2026/11/2026-11-04.md"

    private func makeFixture() throws -> TagGroupFixture {
        let fixture = try TagGroupFixture()
        try fixture.write("# 2026-11-04\n\n- [ ] Ranní\n- [x] Hotový\n", to: Self.day)
        try fixture.write("# Plán\n\n- [ ] První\n- [ ] Druhý\n", to: Self.plan)
        return fixture
    }

    /// A model in Tasks mode whose Task Overview reflects the indexed Vault.
    private func makeModelShowingTasks(_ fixture: TagGroupFixture) async throws -> AppModel {
        let model = fixture.makeModel()
        try await waitUntil { !model.isIndexing }
        model.sidebarMode = .tasks
        try await waitForTasks(model) { !$0.isEmpty }
        return model
    }

    private func listed(_ model: AppModel) -> [TaskOccurrence]? {
        guard case .loaded(let tasks) = model.taskOverview.tasks else { return nil }
        return tasks
    }

    private func waitForTasks(_ model: AppModel, _ condition: @escaping ([String]) -> Bool) async throws {
        try await waitUntil { listed(model).map { condition($0.map(\.text)) } ?? false }
    }

    private func url(_ fixture: TagGroupFixture, _ relativePath: String) -> URL {
        fixture.rootURL.appending(path: relativePath, directoryHint: .notDirectory)
    }

    @Test("Úkoly shows all saved Open Tasks by default and Completed Tasks on request")
    func browsesByFilter() async throws {
        let fixture = try makeFixture()
        let model = try await makeModelShowingTasks(fixture)

        #expect(model.taskOverview.filter == .open)
        try await waitForTasks(model) { $0 == ["Ranní", "První", "Druhý"] }

        model.selectTaskFilter(.completed)
        try await waitForTasks(model) { $0 == ["Hotový"] }
    }

    @Test("unsaved edits are not listed; a successful save is")
    func savedContentOnly() async throws {
        let fixture = try makeFixture()
        let model = try await makeModelShowingTasks(fixture)
        let document = try #require(model.openNote(at: url(fixture, Self.plan)))
        document.text += "- [ ] Neuložený\n"
        model.sidebarMode = .tasks
        try await waitForTasks(model) { $0 == ["Ranní", "První", "Druhý"] }

        let revision = model.searchIndexRevision
        #expect(model.save(documentID: document.id))
        try await waitUntil { model.searchIndexRevision > revision }
        model.sidebarMode = .tasks
        try await waitForTasks(model) { $0 == ["Ranní", "První", "Druhý", "Neuložený"] }
    }

    @Test("changes and deletions made outside the app refresh the list")
    func outsideChanges() async throws {
        let fixture = try makeFixture()
        let model = try await makeModelShowingTasks(fixture)

        try fixture.write("# Plán\n\n- [x] První\n- [ ] Druhý\n", to: Self.plan)
        model.handleVaultChange(VaultChange(relativePaths: [Self.plan]))
        try await waitForTasks(model) { $0 == ["Ranní", "Druhý"] }

        try FileManager.default.removeItem(at: url(fixture, Self.day))
        model.handleVaultChange(VaultChange(relativePaths: [Self.day]))
        try await waitForTasks(model) { $0 == ["Druhý"] }
    }

    @Test("opening a Task reuses its tab and unsaved text, reveals the Task, and keeps the filter and the opened row for the return")
    func opensSource() async throws {
        let fixture = try makeFixture()
        let model = try await makeModelShowingTasks(fixture)
        let saved = try fixture.read(Self.plan)
        let document = try #require(model.openNote(at: url(fixture, Self.plan)))
        document.text = saved + "Dopsáno, neuloženo\n"
        let tabs = model.tabSession.documents.map(\.id)
        model.sidebarMode = .tasks
        try await waitForTasks(model) { $0.contains("Druhý") }
        let second = try #require(listed(model)?.first { $0.text == "Druhý" })

        model.openTask(second)

        #expect(model.sidebarMode == .journal)
        #expect(model.tabSession.documents.map(\.id) == tabs)
        #expect(model.document?.id == document.id)
        #expect(document.text == saved + "Dopsáno, neuloženo\n")
        let reveal = try #require(model.reveal)
        #expect(reveal.documentID == AnyHashable(document.id))
        #expect((document.text as NSString).substring(with: reveal.range) == "[ ]")
        #expect(reveal.range.location == second.boxLocation)
        #expect(model.errorMessage == nil)
        #expect(try fixture.read(Self.plan) == saved)

        model.sidebarMode = .tasks
        #expect(model.taskOverview.filter == .open)
        #expect(model.taskOverview.selectedTaskID == second.id)
    }

    @Test("a Task opens a note that is not open yet in a new tab")
    func opensNewTab() async throws {
        let fixture = try makeFixture()
        let model = try await makeModelShowingTasks(fixture)
        let ranni = try #require(listed(model)?.first { $0.text == "Ranní" })

        model.openTask(ranni)

        let document = try #require(model.document)
        #expect(document.fileURL.standardizedFileURL == url(fixture, Self.day).standardizedFileURL)
        #expect(model.reveal?.range.location == ranni.boxLocation)
    }

    @Test("when unsaved edits moved or changed the Task, the note opens with a warning and nothing unrelated is revealed")
    func unsafeLocation() async throws {
        let fixture = try makeFixture()
        let model = try await makeModelShowingTasks(fixture)
        let document = try #require(model.openNote(at: url(fixture, Self.plan)))
        document.text = "# Plán\n\nÚvod navíc\n- [ ] První\n- [ ] Druhý\n"
        model.sidebarMode = .tasks
        try await waitForTasks(model) { $0.contains("Druhý") }
        let second = try #require(listed(model)?.first { $0.text == "Druhý" })

        model.openTask(second)

        #expect(model.document?.id == document.id)
        #expect(model.reveal == nil)
        #expect(model.errorMessage?.contains("Druhý") == true)
        #expect(document.hasUnsavedChanges)
    }

    @Test("a Task whose note was deleted creates no note and says so")
    func missingSource() async throws {
        let fixture = try makeFixture()
        let model = try await makeModelShowingTasks(fixture)
        let first = try #require(listed(model)?.first { $0.text == "První" })
        let tabs = model.tabSession.documents.map(\.id)
        try FileManager.default.removeItem(at: url(fixture, Self.plan))

        model.openTask(first)

        #expect(model.tabSession.documents.map(\.id) == tabs)
        #expect(model.errorMessage != nil)
        #expect(!FileManager.default.fileExists(atPath: url(fixture, Self.plan).path))
        #expect(model.sidebarMode == .tasks)
        try await waitForTasks(model) { !$0.contains("První") }
    }

    @Test("a new Daily Entry that has no saved file yet contributes no Tasks")
    func unsavedNewNote() async throws {
        let fixture = try makeFixture()
        let model = try await makeModelShowingTasks(fixture)
        model.openToday()
        let today = try #require(model.document)
        #expect(!FileManager.default.fileExists(atPath: today.fileURL.path))
        today.text += "\n- [ ] Jen v paměti\n"
        let revision = model.searchIndexRevision
        model.handleVaultChange(VaultChange(relativePaths: [""], requiresFullRescan: true))
        try await waitUntil { model.searchIndexRevision > revision }

        model.sidebarMode = .tasks
        try await waitForTasks(model) { $0 == ["Ranní", "První", "Druhý"] }
        #expect(!FileManager.default.fileExists(atPath: today.fileURL.path))
    }

    @Test("a failed save leaves the listed Tasks as they were saved before")
    func failedSave() async throws {
        let fixture = try makeFixture()
        let model = try await makeModelShowingTasks(fixture)
        let document = try #require(model.openNote(at: url(fixture, Self.plan)))
        document.text = "# Plán\n\n- [x] První\n- [ ] Druhý\n- [ ] Nový\n"
        let folder = url(fixture, "Projekty")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        #expect(!model.save(documentID: document.id))
        #expect(model.errorMessage != nil)
        #expect(document.hasUnsavedChanges)

        model.sidebarMode = .tasks
        await model.taskOverview.refresh()
        #expect(listed(model)?.map(\.text) == ["Ranní", "První", "Druhý"])
    }

    @Test("after switching Vaults only the new Vault's Tasks are listed and an old row opens nothing")
    func switchingVaults() async throws {
        let first = try makeFixture()
        let second = try TagGroupFixture()
        try second.write("# Jinde\n\n- [ ] Z druhého Vaultu\n", to: "Jinde.md")
        let model = try await makeModelShowingTasks(first)
        let stale = try #require(listed(model)?.first { $0.text == "První" })

        model.chooseVault(at: second.rootURL)
        try await waitUntil { !model.isIndexing }
        model.sidebarMode = .tasks
        try await waitForTasks(model) { $0 == ["Z druhého Vaultu"] }
        let tabs = model.tabSession.documents.map(\.id)

        model.openTask(stale)

        #expect(model.tabSession.documents.map(\.id) == tabs)
        #expect(model.sidebarMode == .tasks)
        #expect(!FileManager.default.fileExists(atPath: second.rootURL.appending(path: Self.plan).path))
    }

    @Test("browsing Tasks writes nothing to the notes")
    func browsingIsReadOnly() async throws {
        let fixture = try makeFixture()
        let before = try [fixture.read(Self.day), fixture.read(Self.plan)]
        let model = try await makeModelShowingTasks(fixture)
        model.selectTaskFilter(.completed)
        try await waitForTasks(model) { $0 == ["Hotový"] }
        model.selectTaskFilter(.open)
        try await waitForTasks(model) { $0 == ["Ranní", "První", "Druhý"] }
        #expect(try [fixture.read(Self.day), fixture.read(Self.plan)] == before)
    }
}
