import Foundation
import Testing
@testable import NotessCore

@Suite("Tag Groups")
struct TagGroupsTests {
    @Test("names are trimmed, required and unique ignoring case")
    func names() throws {
        var groups = TagGroups()
        let id = try groups.create(named: "  Projekty ")

        #expect(groups.groups.map(\.name) == ["Projekty"])
        #expect(groups.groups.first?.id == id)
        #expect(throws: TagGroupError.emptyName) { try groups.create(named: " \n") }
        #expect(throws: TagGroupError.duplicateName("projekty")) { try groups.create(named: "projekty") }
    }

    @Test("memberships use Tag identity and stay sorted without duplicates")
    func membershipsUseTagIdentity() throws {
        var groups = TagGroups()
        let id = try groups.create(named: "Klienti")

        groups.add(tag: "#Zeta", to: id)
        groups.add(tag: "acme", to: id)
        groups.add(tag: "ACME", to: id)
        #expect(groups.groups.first?.tags == ["acme", "zeta"])

        groups.remove(tag: "#Acme", from: id)
        #expect(groups.groups.first?.tags == ["zeta"])
    }

    @Test("the sidebar hides Tags outside the vocabulary and keeps All Tags complete")
    func sidebar() throws {
        var groups = TagGroups()
        let work = try groups.create(named: "Práce")
        let empty = try groups.create(named: "Archiv")
        groups.add(tag: "acme", to: work)
        groups.add(tag: "gone", to: work)
        groups.setExpanded(false, for: empty)

        let sidebar = groups.sidebar(vocabulary: ["acme", "beta"])

        #expect(sidebar.groups.map(\.name) == ["Archiv", "Práce"])
        #expect(sidebar.groups.map(\.isExpanded) == [false, true])
        #expect(sidebar.groups.map(\.tags) == [[], ["acme"]])
        #expect(sidebar.allTags == ["acme", "beta"])
        #expect(groups.groups.first { $0.id == work }?.tags == ["acme", "gone"])
    }

    @Test("ungrouped Tags are the vocabulary Tags in no group, in vocabulary order")
    func ungrouped() throws {
        var groups = TagGroups()
        #expect(groups.sidebar(vocabulary: ["acme", "beta"]).ungroupedTags.isEmpty)

        let work = try groups.create(named: "Práce")
        let clients = try groups.create(named: "Klienti")
        #expect(groups.sidebar(vocabulary: ["acme", "beta", "acme"]).ungroupedTags == ["acme", "beta"])

        groups.add(tag: "beta", to: work)
        groups.add(tag: "beta", to: clients)
        groups.add(tag: "gone", to: work)
        #expect(groups.sidebar(vocabulary: ["acme", "beta", "zeta"]).ungroupedTags == ["acme", "zeta"])

        groups.remove(tag: "beta", from: work)
        #expect(groups.sidebar(vocabulary: ["acme", "beta"]).ungroupedTags == ["acme"])
        groups.delete(clients)
        #expect(groups.sidebar(vocabulary: ["acme", "beta"]).ungroupedTags == ["acme", "beta"])
        #expect(groups.sidebar(vocabulary: ["acme", "beta"]).allTags == ["acme", "beta"])
    }

    @Test("deleting a group leaves the others")
    func delete() throws {
        var groups = TagGroups()
        let first = try groups.create(named: "A")
        _ = try groups.create(named: "B")

        groups.delete(first)

        #expect(groups.groups.map(\.name) == ["B"])
    }
}

@Suite("Tag Groups: per-Vault store")
struct TagGroupStoreTests {
    private func makeStore() -> (TagGroupStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotessTagGroups-\(UUID().uuidString)", isDirectory: true)
        return (TagGroupStore(directoryURL: directory), directory)
    }

    @Test("a Vault without stored groups has none")
    func noGroupsYet() throws {
        let temp = try TemporaryVault()
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try store.groups(for: temp.vault) == TagGroups())
    }

    @Test("remembers groups per Vault")
    func remembersPerVault() throws {
        let first = try TemporaryVault()
        let second = try TemporaryVault()
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var groups = TagGroups()
        let id = try groups.create(named: "Projekty")
        groups.add(tag: "acme", to: id)
        groups.setExpanded(false, for: id)

        try store.remember(groups, for: first.vault)

        #expect(try TagGroupStore(directoryURL: directory).groups(for: first.vault) == groups)
        #expect(try store.groups(for: second.vault) == TagGroups())
    }

    @Test("an unreadable or unknown file is an error, not empty groups")
    func unreadableFile() throws {
        let temp = try TemporaryVault()
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.remember(TagGroups(), for: temp.vault)
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)

        try Data(#"{"version":2,"vaultPath":"/x","groups":[]}"#.utf8).write(to: file)
        #expect(throws: (any Error).self) { try store.groups(for: temp.vault) }

        try Data("not json".utf8).write(to: file)
        #expect(throws: (any Error).self) { try store.groups(for: temp.vault) }
    }
}
