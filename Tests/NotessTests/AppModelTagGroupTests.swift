import Foundation
import Testing
@testable import Notess
@testable import NotessCore

@MainActor
@Suite("Tag Groups in the Tags sidebar")
struct AppModelTagGroupTests {
    @Test("an empty named group appears in the Tags sidebar and survives reopening the Vault")
    func createsEmptyGroup() async throws {
        let fixture = try TagGroupFixture()
        try fixture.write("# 2026-06-02\n\n## Porada #acme\n", to: "Journal/2026/06/2026-06-02.md")
        let model = try await fixture.makeModelShowingTags()

        #expect(model.createTagGroup(named: "  Projekty  ") != nil)

        #expect(try sidebarGroups(model) == [GroupRow(name: "Projekty", isExpanded: true, tags: [])])
        #expect(try #require(model.tagSidebar).allTags == ["acme"])
        #expect(model.errorMessage == nil)

        let reopened = try await fixture.makeModelShowingTags()
        #expect(try sidebarGroups(reopened) == [GroupRow(name: "Projekty", isExpanded: true, tags: [])])
    }

    @Test("a Tag joins an existing and a new group additively and stays once in All Tags")
    func addsTagToSeveralGroups() async throws {
        let fixture = try TagGroupFixture()
        try fixture.write("# 2026-06-02\n\n## Porada #Acme #beta\n", to: "Journal/2026/06/2026-06-02.md")
        try fixture.write("# 2026-06-01\n\n## Start #ACME\n", to: "Journal/2026/06/2026-06-01.md")
        let model = try await fixture.makeModelShowingTags()
        let projects = try #require(model.createTagGroup(named: "Projekty"))

        model.addTag("acme", toGroup: projects)
        model.addTag("#ACME", toGroup: projects)
        #expect(model.addTagToNewGroup("acme", named: "Klienti") != nil)
        model.addTag("beta", toGroup: projects)

        #expect(try sidebarGroups(model) == [
            GroupRow(name: "Klienti", isExpanded: true, tags: ["acme"]),
            GroupRow(name: "Projekty", isExpanded: true, tags: ["acme", "beta"]),
        ])
        #expect(try #require(model.tagSidebar).allTags == ["acme", "beta"])
        #expect(model.errorMessage == nil)
    }

    @Test("a group name must be non-empty and new; a refused name changes nothing")
    func refusesUnusableNames() async throws {
        let fixture = try TagGroupFixture()
        try fixture.write("# 2026-06-02\n\n## Porada #acme\n", to: "Journal/2026/06/2026-06-02.md")
        let model = try await fixture.makeModelShowingTags()
        let projects = try #require(model.createTagGroup(named: "Projekty"))
        model.addTag("acme", toGroup: projects)

        #expect(model.createTagGroup(named: "   ") == nil)
        #expect(model.errorMessage != nil)
        model.errorMessage = nil
        #expect(model.addTagToNewGroup("acme", named: "projekty") == nil)
        #expect(model.errorMessage != nil)

        #expect(try sidebarGroups(model) == [GroupRow(name: "Projekty", isExpanded: true, tags: ["acme"])])
    }

    @Test("a grouped Tag opens the same Tag Timeline of saved Daily Entries as in All Tags")
    func groupedTagOpensTimeline() async throws {
        let fixture = try TagGroupFixture()
        try fixture.write("# 2026-06-02\n\n## Porada #acme\nzápis\n", to: "Journal/2026/06/2026-06-02.md")
        try fixture.write("## Volná #acme #volna\nx\n", to: "Notes/Volná.md")
        try fixture.write("## Fakt #acme\n", to: "_brain/Lidé/Acme.md")
        let model = try await fixture.makeModelShowingTags()
        let projects = try #require(model.createTagGroup(named: "Projekty"))
        model.addTag("acme", toGroup: projects)
        model.addTag("volna", toGroup: projects)

        let sidebar = try #require(model.tagSidebar)
        #expect(sidebar.allTags == ["acme"])
        let grouped = try #require(sidebar.groups.first?.tags)
        #expect(grouped == ["acme"])

        model.selectTimelineTag(grouped[0])
        try await waitUntil {
            if case .loaded? = model.tagTimeline.timeline { return true }
            return false
        }
        guard case .loaded(let days)? = model.tagTimeline.timeline else { return }
        #expect(model.tagTimeline.selectedTag == "acme")
        #expect(days.flatMap { $0.sections.map(\.relativePath) } == ["Journal/2026/06/2026-06-02.md"])
    }

    @Test("removing a membership or deleting a group changes only that organisation, never notes")
    func removalChangesOnlyOrganisation() async throws {
        let fixture = try TagGroupFixture()
        let entry = "# 2026-06-02\n\n## Porada #acme #beta\n"
        try fixture.write(entry, to: "Journal/2026/06/2026-06-02.md")
        let model = try await fixture.makeModelShowingTags()
        let projects = try #require(model.createTagGroup(named: "Projekty"))
        let clients = try #require(model.addTagToNewGroup("acme", named: "Klienti"))
        model.addTag("acme", toGroup: projects)
        model.addTag("beta", toGroup: projects)

        model.removeTag("acme", fromGroup: projects)
        #expect(try sidebarGroups(model) == [
            GroupRow(name: "Klienti", isExpanded: true, tags: ["acme"]),
            GroupRow(name: "Projekty", isExpanded: true, tags: ["beta"]),
        ])

        model.removeTag("acme", fromGroup: clients)
        model.deleteTagGroup(projects)
        #expect(try sidebarGroups(model) == [GroupRow(name: "Klienti", isExpanded: true, tags: [])])
        #expect(try #require(model.tagSidebar).allTags == ["acme", "beta"])
        #expect(try fixture.read("Journal/2026/06/2026-06-02.md") == entry)
        #expect(model.hasUnsavedChanges == false)
        #expect(model.errorMessage == nil)

        let reopened = try await fixture.makeModelShowingTags()
        #expect(try sidebarGroups(reopened) == [GroupRow(name: "Klienti", isExpanded: true, tags: [])])
    }

    @Test("collapsing a group hides nothing else and is remembered")
    func collapseIsRemembered() async throws {
        let fixture = try TagGroupFixture()
        try fixture.write("# 2026-06-02\n\n## Porada #acme\n", to: "Journal/2026/06/2026-06-02.md")
        let model = try await fixture.makeModelShowingTags()
        let projects = try #require(model.addTagToNewGroup("acme", named: "Projekty"))
        _ = try #require(model.createTagGroup(named: "Osobní"))

        model.setTagGroup(projects, isExpanded: false)

        let expected = [
            GroupRow(name: "Osobní", isExpanded: true, tags: []),
            GroupRow(name: "Projekty", isExpanded: false, tags: ["acme"]),
        ]
        #expect(try sidebarGroups(model) == expected)
        let reopened = try await fixture.makeModelShowingTags()
        #expect(try sidebarGroups(reopened) == expected)

        reopened.setTagGroup(projects, isExpanded: true)
        #expect(try sidebarGroups(reopened).last?.isExpanded == true)
    }

    @Test("a Tag without saved Journal occurrences hides but keeps its groups and returns to them")
    func disappearingTagKeepsMemberships() async throws {
        let fixture = try TagGroupFixture()
        let path = "Journal/2026/06/2026-06-02.md"
        try fixture.write("# 2026-06-02\n\n## Porada #acme #beta\n", to: path)
        let model = try await fixture.makeModelShowingTags()
        let projects = try #require(model.addTagToNewGroup("acme", named: "Projekty"))
        model.addTag("beta", toGroup: projects)
        _ = try #require(model.addTagToNewGroup("acme", named: "Klienti"))

        try await fixture.save("# 2026-06-02\n\n## Porada #beta\n", to: path, in: model)
        try await waitUntil { model.tagSidebar?.allTags == ["beta"] }
        #expect(try sidebarGroups(model) == [
            GroupRow(name: "Klienti", isExpanded: true, tags: []),
            GroupRow(name: "Projekty", isExpanded: true, tags: ["beta"]),
        ])

        // An unsaved #acme does not bring it back; only a save does.
        let document = try #require(model.openNote(at: fixture.rootURL.appending(path: path)))
        document.text = "# 2026-06-02\n\n## Porada #beta #acme\n"
        model.sidebarMode = .tags
        await model.tagTimeline.refresh()
        #expect(try sidebarGroups(model).first?.tags == [])

        let reopened = try await fixture.makeModelShowingTags()
        #expect(try sidebarGroups(reopened).first?.tags == [])
        try await fixture.save("# 2026-06-03\n\n## Návrat #ACME\n", to: "Journal/2026/06/2026-06-03.md", in: reopened)
        try await waitUntil { reopened.tagSidebar?.allTags == ["acme", "beta"] }
        #expect(try sidebarGroups(reopened) == [
            GroupRow(name: "Klienti", isExpanded: true, tags: ["acme"]),
            GroupRow(name: "Projekty", isExpanded: true, tags: ["acme", "beta"]),
        ])
    }

    @Test("rebuilding the search index keeps the groups")
    func rebuildKeepsGroups() async throws {
        let fixture = try TagGroupFixture()
        try fixture.write("# 2026-06-02\n\n## Porada #acme\n", to: "Journal/2026/06/2026-06-02.md")
        let model = try await fixture.makeModelShowingTags()
        let projects = try #require(model.addTagToNewGroup("acme", named: "Projekty"))
        model.setTagGroup(projects, isExpanded: false)
        let expected = [GroupRow(name: "Projekty", isExpanded: false, tags: ["acme"])]

        model.rebuildSearchIndex()
        try await fixture.settle(model)
        #expect(try sidebarGroups(model) == expected)

        let reopened = try await fixture.makeModelShowingTags()
        #expect(try sidebarGroups(reopened) == expected)
        #expect(model.errorMessage == nil)
    }

    @Test("each Vault has its own groups, also after switching back and forth")
    func vaultsAreIsolated() async throws {
        let first = try TagGroupFixture()
        try first.write("# 2026-06-02\n\n## Porada #acme\n", to: "Journal/2026/06/2026-06-02.md")
        let second = try TagGroupFixture(settingsURL: first.settingsURL)
        try second.write("# 2026-06-02\n\n## Porada #acme\n", to: "Journal/2026/06/2026-06-02.md")
        let model = try await first.makeModelShowingTags()
        _ = try #require(model.addTagToNewGroup("acme", named: "První"))

        model.chooseVault(at: second.rootURL)
        model.sidebarMode = .tags
        try await second.settle(model)
        #expect(try sidebarGroups(model) == [])
        _ = try #require(model.createTagGroup(named: "Druhá"))

        model.chooseVault(at: first.rootURL)
        model.sidebarMode = .tags
        try await first.settle(model)
        #expect(try sidebarGroups(model) == [GroupRow(name: "První", isExpanded: true, tags: ["acme"])])

        model.chooseVault(at: second.rootURL)
        model.sidebarMode = .tags
        try await second.settle(model)
        #expect(try sidebarGroups(model) == [GroupRow(name: "Druhá", isExpanded: true, tags: [])])
    }

    @Test("unreadable Tag Group settings are reported and not overwritten")
    func unreadableSettingsAreReported() async throws {
        let fixture = try TagGroupFixture()
        try fixture.write("# 2026-06-02\n\n## Porada #acme\n", to: "Journal/2026/06/2026-06-02.md")
        let model = try await fixture.makeModelShowingTags()
        _ = try #require(model.createTagGroup(named: "Projekty"))
        let directory = fixture.settingsURL.appending(path: "TagGroups", directoryHint: .isDirectory)
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data("not json".utf8).write(to: file)

        let reopened = try await fixture.makeModelShowingTags()
        #expect(reopened.errorMessage != nil)
        #expect(try sidebarGroups(reopened) == [])
        reopened.errorMessage = nil

        #expect(reopened.createTagGroup(named: "Nová") == nil)
        #expect(reopened.errorMessage != nil)
        #expect(try Data(contentsOf: file) == Data("not json".utf8))
    }

    @Test("a group change that cannot be saved is reported and not shown")
    func unsavableChangeIsReported() async throws {
        let fixture = try TagGroupFixture()
        try fixture.write("# 2026-06-02\n\n## Porada #acme\n", to: "Journal/2026/06/2026-06-02.md")
        try FileManager.default.createDirectory(at: fixture.settingsURL, withIntermediateDirectories: true)
        try Data().write(to: fixture.settingsURL.appending(path: "TagGroups", directoryHint: .notDirectory))
        let model = try await fixture.makeModelShowingTags()

        #expect(model.createTagGroup(named: "Projekty") == nil)

        #expect(model.errorMessage != nil)
        #expect(try sidebarGroups(model) == [])
    }
}

/// What a reader sees of one group: its name, whether it is open and its Tags.
struct GroupRow: Equatable {
    let name: String
    let isExpanded: Bool
    let tags: [String]
}

@MainActor
func sidebarGroups(_ model: AppModel) throws -> [GroupRow] {
    try #require(model.tagSidebar).groups.map {
        GroupRow(name: $0.name, isExpanded: $0.isExpanded, tags: $0.tags)
    }
}

/// Polls until `condition` holds, failing after a generous deadline.
@MainActor
func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(20)
    while !condition() {
        try #require(ContinuousClock.now < deadline, "timed out")
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// A temporary Vault with isolated preferences and a Tag Group settings
/// directory outside it, shared by every model the fixture makes.
final class TagGroupFixture {
    let rootURL: URL
    let settingsURL: URL
    private let defaultsSuiteName: String
    private let defaults: UserDefaults

    init(settingsURL: URL? = nil) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: "NotessTagGroupTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        self.settingsURL = settingsURL ?? FileManager.default.temporaryDirectory
            .appending(path: "NotessTagGroupSettings-\(UUID().uuidString)", directoryHint: .isDirectory)
        defaultsSuiteName = "NotessTagGroupTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: rootURL)
        try? FileManager.default.removeItem(at: settingsURL)
    }

    func write(_ text: String, to relativePath: String) throws {
        let url = rootURL.appending(path: relativePath, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ relativePath: String) throws -> String {
        try String(contentsOf: rootURL.appending(path: relativePath, directoryHint: .notDirectory), encoding: .utf8)
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
                directoryURL: settingsURL.appending(path: "BrainRuns", directoryHint: .isDirectory)
            ),
            tagGroupStore: TagGroupStore(
                directoryURL: settingsURL.appending(path: "TagGroups", directoryHint: .isDirectory)
            ),
            now: { Date(timeIntervalSince1970: 1_760_765_000) }
        )
    }

    /// A model in Tags mode whose Tag list reflects the indexed Vault.
    @MainActor
    func makeModelShowingTags() async throws -> AppModel {
        let model = makeModel()
        model.sidebarMode = .tags
        try await settle(model)
        return model
    }

    /// Waits for indexing to finish and the Tag list to show the result.
    @MainActor
    func settle(_ model: AppModel) async throws {
        try await waitUntil { !model.isIndexing }
        await refreshTags(model)
        _ = try #require(model.tagSidebar)
    }

    /// Saves `text` as the note at `relativePath` through the app and waits
    /// until the Tag list reflects the save.
    @MainActor
    func save(_ text: String, to relativePath: String, in model: AppModel) async throws {
        let document = try #require(model.openNote(
            at: rootURL.appending(path: relativePath, directoryHint: .notDirectory)
        ))
        document.text = text
        let revision = model.searchIndexRevision
        #expect(model.save(documentID: document.id))
        try await waitUntil { model.searchIndexRevision > revision }
        model.sidebarMode = .tags
        await refreshTags(model)
    }

    /// Lets refreshes the app already started go first, then loads the Tag
    /// list again. A test expecting a change still waits for it: a later
    /// refresh may replace this one's answer.
    @MainActor
    func refreshTags(_ model: AppModel) async {
        for _ in 0..<10 { await Task.yield() }
        await model.tagTimeline.refresh()
    }
}
