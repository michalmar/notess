import Foundation
import Testing
@testable import NotessCore

@Suite("Fulltext search index")
final class SearchIndexTests {
    private let vault: TemporaryVault
    private let databaseURL: URL

    init() throws {
        vault = try TemporaryVault()
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotessSearchTests-\(UUID().uuidString)")
            .appendingPathComponent("index.sqlite")
        try vault.write("""
        # 2026-03-14

        Ráno káva.

        ## Kickoff Acme
        Přehled požadavků od klienta. #acme

        ## Retro
        Kickoff šel dobře.
        """, to: "Journal/2026/03/2026-03-14.md")
        try vault.write("# Plán\ncreated: 2026-03-01\n\n## Požadavky\nPřehled a kickoff #ACME\n", to: "Projekty/Plán.md")
        try vault.write("# Acme\n\n## Fakta\nKlient od roku 2020 [[2026-03-14#Retro]]\n", to: "_brain/companies/Acme.md")
    }

    deinit {
        try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
    }

    private func makeIndex() -> SearchIndex {
        SearchIndex(vault: vault.vault, databaseURL: databaseURL)
    }

    private func titles(_ groups: [SearchResultGroup]) -> [NoteKind: [String]] {
        Dictionary(uniqueKeysWithValues: groups.map { group in
            (group.kind, group.results.map { "\($0.noteName)#\($0.title ?? "")" })
        })
    }

    @Test("results are Sections grouped Journal, Notes, Brain")
    func groupsByKind() async throws {
        let index = makeIndex()
        try await index.synchronize()
        let groups = try await index.search(SearchQuery("kickoff"))
        #expect(groups.map(\.kind) == [.dailyEntry, .freeNote])
        #expect(titles(groups)[.dailyEntry]?.sorted() == ["2026-03-14#Kickoff Acme", "2026-03-14#Retro"])
        #expect(titles(groups)[.freeNote] == ["Plán#Požadavky"])

        let brain = try await index.search(SearchQuery("klient"))
        #expect(brain.map(\.kind) == [.dailyEntry, .brainNote])
    }

    @Test("the text before the first Section is searchable on its own")
    func preamble() async throws {
        let index = makeIndex()
        try await index.synchronize()
        let groups = try await index.search(SearchQuery("káva"))
        let result = try #require(groups.first?.results.first)
        #expect(result.title == "2026-03-14")
        #expect(result.ordinal == 0)
        #expect(result.relativePath == "Journal/2026/03/2026-03-14.md")
    }

    @Test("the preview highlights the match")
    func snippetHighlight() async throws {
        let index = makeIndex()
        try await index.synchronize()
        let result = try #require(try await index.search(SearchQuery("požadavků")).first?.results.first)
        #expect(result.snippet.text == "Přehled požadavků od klienta. #acme")
        #expect(result.snippet.parts.filter(\.isMatch).map(\.text) == ["požadavků"])
    }

    @Test("search ignores case and diacritics and matches word prefixes")
    func diacritics() async throws {
        let index = makeIndex()
        try await index.synchronize()
        for query in ["přehled", "PREHLED", "Přehl", "prehle"] {
            let groups = try await index.search(SearchQuery(query))
            #expect(groups.flatMap(\.results).count == 2, "\(query)")
        }
        let title = try #require(try await index.search(SearchQuery("pozadavky")).first?.results.first)
        #expect(title.highlightedTitle.parts.filter(\.isMatch).map(\.text) == ["Požadavky"])
    }

    @Test("#tag filters to Sections with that Tag, ignoring case")
    func tagFilter() async throws {
        let index = makeIndex()
        try await index.synchronize()
        let groups = try await index.search(SearchQuery("#Acme kickoff"))
        #expect(titles(groups) == [.dailyEntry: ["2026-03-14#Kickoff Acme"], .freeNote: ["Plán#Požadavky"]])
        #expect(try await index.search(SearchQuery("#acme retro")).isEmpty)
    }

    @Test("a Tag-only query lists tagged Sections with the Tag highlighted")
    func tagOnly() async throws {
        let index = makeIndex()
        try await index.synchronize()
        let groups = try await index.search(SearchQuery("#acme"))
        #expect(groups.flatMap(\.results).count == 2)
        let plan = try #require(groups.last?.results.first)
        #expect(plan.snippet.parts.filter(\.isMatch).map(\.text) == ["#ACME"])
    }

    @Test("queries with FTS5 syntax characters do not fail")
    func syntaxCharacters() async throws {
        let index = makeIndex()
        try await index.synchronize()
        for query in ["\"", "AND OR (", "NEAR(", "*", "a:b", "-x"] {
            _ = try await index.search(SearchQuery(query))
        }
        #expect(try await index.search(SearchQuery("")).isEmpty)
    }

    @Test("updating paths re-reads changed files and forgets deleted ones")
    func update() async throws {
        let index = makeIndex()
        try await index.synchronize()
        try vault.write("# Plán\n\n## Nové\nRozpočet\n", to: "Projekty/Plán.md")
        try FileManager.default.removeItem(at: vault.vault.rootURL.appending(path: "_brain"))
        try vault.write("## Jinde\nRozpočet taky\n", to: "Nová složka/Další.md")
        try await index.update(relativePaths: ["Projekty/Plán.md", "_brain", "Nová složka"])

        let budget = try await index.search(SearchQuery("rozpočet"))
        #expect(budget.map(\.kind) == [.freeNote])
        #expect(titles(budget)[.freeNote]?.sorted() == ["Další#Jinde", "Plán#Nové"])
        #expect(try await index.search(SearchQuery("přehled")).flatMap(\.results).map(\.relativePath)
            == ["Journal/2026/03/2026-03-14.md"])
        #expect(try await index.search(SearchQuery("klient")).map(\.kind) == [.dailyEntry])
    }

    @Test("an unreadable note is tried again on the next synchronisation, even with an unchanged stamp")
    func unreadableNoteRetried() async throws {
        let index = makeIndex()
        let url = vault.vault.rootURL.appending(path: "Rozbitá.md")
        try Data([0x23, 0x23, 0x20, 0xFF, 0xFE, 0x0A, 0x61]).write(to: url)
        let modified = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        try await index.synchronize()

        try Data("## Ok\nb".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        try await index.synchronize()
        #expect(try await index.search(SearchQuery("ok")).first?.results.first?.relativePath == "Rozbitá.md")
    }

    @Test("a saved note is re-indexed by its file URL")
    func updateSavedFile() async throws {
        let index = makeIndex()
        try await index.synchronize()
        try vault.write("## Po uložení\nnový obsah\n", to: "Projekty/Plán.md")
        try await index.update(fileAt: vault.vault.rootURL.appending(path: "Projekty/Plán.md"))
        #expect(try await index.search(SearchQuery("obsah")).first?.results.first?.title == "Po uložení")
        try await index.update(fileAt: URL(filePath: "/tmp/elsewhere.md"))
    }

    @Test("on start the index catches up with changes made while the app was closed")
    func catchUp() async throws {
        try await makeIndex().synchronize()
        try vault.write("## Večer\nkino\n", to: "Journal/2026/03/2026-03-15.md")
        try FileManager.default.removeItem(at: vault.vault.rootURL.appending(path: "Projekty/Plán.md"))

        let reopened = makeIndex()
        try await reopened.synchronize()
        #expect(try await reopened.search(SearchQuery("kino")).first?.results.first?.title == "Večer")
        #expect(try await reopened.search(SearchQuery("#acme")).flatMap(\.results).count == 1)
    }

    @Test("hidden files and non-Markdown files are not indexed")
    func hidden() async throws {
        try vault.write("## Skryté\ntajemství\n", to: ".trash/stará.md")
        try vault.write("tajemství", to: "poznámka.txt")
        let index = makeIndex()
        try await index.synchronize()
        #expect(try await index.search(SearchQuery("tajemství")).isEmpty)
    }

    @Test("the index can be fully rebuilt, also from a damaged file")
    func rebuild() async throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: databaseURL)
        let index = makeIndex()
        try await index.synchronize()
        #expect(try await index.search(SearchQuery("kickoff")).flatMap(\.results).count == 3)
        try await index.rebuild()
        #expect(try await index.search(SearchQuery("kickoff")).flatMap(\.results).count == 3)
    }

    @Test("an index from another schema version is discarded")
    func outdatedSchema() async throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = try SQLiteDatabase(url: databaseURL)
        try old.execute("CREATE TABLE files (path TEXT); PRAGMA user_version = 999;")
        let index = makeIndex()
        try await index.synchronize()
        #expect(try await index.search(SearchQuery("káva")).count == 1)
    }

    @Test("the default index location is a cache outside the Vault")
    func location() {
        let url = SearchIndex.defaultDatabaseURL(for: vault.vault)
        #expect(!url.path.hasPrefix(vault.vault.rootURL.path))
        #expect(url.path.contains("/Library/Caches/"))
        #expect(url == SearchIndex.defaultDatabaseURL(for: Vault(rootURL: vault.vault.rootURL)))
        #expect(url != SearchIndex.defaultDatabaseURL(for: Vault(rootURL: URL(filePath: "/tmp/other"))))
    }
}
