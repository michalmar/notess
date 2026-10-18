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

    /// Not valid UTF-8, so reading the note as text fails deterministically.
    private static let invalidUTF8 = Data([0x23, 0x23, 0x20, 0xFF, 0xFE, 0x0A, 0x61])

    private func fileIDs(_ query: String, in index: SearchIndex) async throws -> [String] {
        try await index.search(SearchQuery(query)).flatMap(\.results).map(\.relativePath)
    }

    @Test("a new unreadable note reports a failure, is not recorded and is tried again with an unchanged stamp")
    func unreadableNoteRetried() async throws {
        let index = makeIndex()
        let url = vault.vault.rootURL.appending(path: "Rozbitá.md")
        try Self.invalidUTF8.write(to: url)
        let modified = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)

        let failure = await #expect(throws: SearchIndex.IndexingFailure.self) { try await index.synchronize() }
        #expect(failure?.files.map(\.relativePath) == ["Rozbitá.md"])
        // The readable notes of the same run are indexed.
        #expect(try await fileIDs("přehled", in: index).contains("Projekty/Plán.md"))
        #expect(!(try await fileIDs("ok", in: index).contains("Rozbitá.md")))

        try Data("## Ok\nb".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        try await index.synchronize()
        #expect(try await fileIDs("ok", in: index) == ["Rozbitá.md"])
    }

    @Test("a failed replacement keeps the previous Sections, search text, Tags and Tag Timeline, and recovery replaces them")
    func failedReplacementKeepsPreviousRecords() async throws {
        let index = makeIndex()
        try await index.synchronize()
        let journal = "Journal/2026/03/2026-03-14.md"
        let timeline = try await index.tagTimeline(for: "acme")
        let tags = try await index.journalTags()
        #expect(timeline.isEmpty == false)

        try Self.invalidUTF8.write(to: vault.vault.rootURL.appending(path: journal))
        try Self.invalidUTF8.write(to: vault.vault.rootURL.appending(path: "Projekty/Plán.md"))

        let failure = await #expect(throws: SearchIndex.IndexingFailure.self) {
            try await index.update(relativePaths: [journal, "Projekty/Plán.md"])
        }
        #expect(failure?.files.map(\.relativePath).sorted() == [journal, "Projekty/Plán.md"])
        #expect(try await index.tagTimeline(for: "acme") == timeline)
        #expect(try await index.journalTags() == tags)
        #expect(try await fileIDs("kickoff", in: index).sorted() == [journal, journal, "Projekty/Plán.md"].sorted())
        #expect(try await fileIDs("#acme", in: index).sorted() == [journal, "Projekty/Plán.md"].sorted())

        // Reopening the committed cache shows the same consistent data.
        let reopened = makeIndex()
        #expect(try await reopened.tagTimeline(for: "acme") == timeline)
        await #expect(throws: SearchIndex.IndexingFailure.self) { try await reopened.synchronize() }
        #expect(try await reopened.tagTimeline(for: "acme") == timeline)

        try vault.write("# 2026-03-14\n\n## Nové #novy\nzcela jiné\n", to: journal)
        try vault.write("## Jiné\nzcela jiné\n", to: "Projekty/Plán.md")
        try await reopened.synchronize()
        #expect(try await reopened.tagTimeline(for: "acme").isEmpty)
        #expect(try await reopened.journalTags() == ["novy"])
        #expect(try await fileIDs("kickoff", in: reopened).isEmpty)
        #expect(try await fileIDs("zcela", in: reopened).sorted() == [journal, "Projekty/Plán.md"].sorted())
    }

    @Test("a note whose explicit reread failed is retried by passive catch-up although its stamp matches the cache")
    func failedExplicitRereadIsRetried() async throws {
        let index = makeIndex()
        let path = "Projekty/Plán.md"
        try pinModificationDate(path)
        try await index.synchronize()

        let bytes = try Data(contentsOf: vault.vault.rootURL.appending(path: path)).count
        // Same size and date as the indexed file, but unreadable.
        try Data(repeating: 0xFF, count: bytes).write(to: vault.vault.rootURL.appending(path: path))
        try pinModificationDate(path)
        await #expect(throws: SearchIndex.IndexingFailure.self) { try await index.update(relativePaths: [path]) }
        await #expect(throws: SearchIndex.IndexingFailure.self) { try await index.synchronize() }
        #expect(try await fileIDs("požadavky", in: index) == [path])

        try replaceKeepingStamp(path, with: String(repeating: "x", count: bytes))
        try await index.synchronize()
        #expect(try await fileIDs("požadavky", in: index).isEmpty)
    }

    @Test("a confirmed deletion still removes the records of an unreadable note without failing")
    func deletionRemovesRecords() async throws {
        let index = makeIndex()
        try await index.synchronize()
        let journal = "Journal/2026/03/2026-03-14.md"
        try Self.invalidUTF8.write(to: vault.vault.rootURL.appending(path: journal))
        await #expect(throws: SearchIndex.IndexingFailure.self) { try await index.update(relativePaths: [journal]) }

        try FileManager.default.removeItem(at: vault.vault.rootURL.appending(path: journal))
        try await index.update(relativePaths: [journal])
        #expect(try await index.tagTimeline(for: "acme").isEmpty)
        #expect(try await fileIDs("kickoff", in: index) == ["Projekty/Plán.md"])
    }

    @Test("a source that vanished after the scan is told apart from one that cannot be read")
    func vanishedSource() throws {
        let root = vault.vault.rootURL
        try Self.invalidUTF8.write(to: root.appending(path: "Rozbitá.md"))
        try vault.write("## Ok\n", to: "Ok.md")
        #expect(SearchIndex.readSource(at: root.appending(path: "Ok.md")) == .text("## Ok\n"))
        #expect(SearchIndex.readSource(at: root.appending(path: "Zmizelá.md")) == .vanished)
        guard case .failed = SearchIndex.readSource(at: root.appending(path: "Rozbitá.md")) else {
            Issue.record("expected a read failure")
            return
        }
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

    /// A whole-second date, so that restoring it reproduces the recorded stamp exactly.
    private static let pinnedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func pinModificationDate(_ paths: String...) throws {
        for path in paths {
            try FileManager.default.setAttributes(
                [.modificationDate: Self.pinnedDate],
                ofItemAtPath: vault.vault.rootURL.appending(path: path).path
            )
        }
    }

    /// Replaces a note by `text` of the same byte length and restores its
    /// pinned modification date, so its stamp equals the one the index recorded.
    private func replaceKeepingStamp(_ path: String, with text: String) throws {
        let url = vault.vault.rootURL.appending(path: path)
        let size = try Data(contentsOf: url).count
        try vault.write(text, to: path)
        #expect(try Data(contentsOf: url).count == size)
        try pinModificationDate(path)
    }

    @Test("an explicit update reads a note again although its size and date are unchanged")
    func explicitSingleFileUpdateIgnoresStamp() async throws {
        let index = makeIndex()
        try vault.write("# Pořadí\n\n## Řada\nalpha\n", to: "Projekty/Pořadí.md")
        try vault.write("# Druhé\n\n## Řada\nalpha\n", to: "Projekty/Druhé.md")
        try pinModificationDate("Projekty/Pořadí.md", "Projekty/Druhé.md")
        try await index.synchronize()
        #expect(try await fileIDs("alpha", in: index).sorted() == ["Projekty/Druhé.md", "Projekty/Pořadí.md"])

        try replaceKeepingStamp("Projekty/Pořadí.md", with: "# Pořadí\n\n## Řada\nomega\n")
        try replaceKeepingStamp("Projekty/Druhé.md", with: "# Druhé\n\n## Řada\nomega\n")
        // Passive catch-up trusts the matching stamps.
        try await index.synchronize()
        #expect(try await fileIDs("omega", in: index).isEmpty)

        try await index.update(fileAt: vault.vault.rootURL.appending(path: "Projekty/Pořadí.md"))
        #expect(try await fileIDs("omega", in: index) == ["Projekty/Pořadí.md"])
        #expect(try await fileIDs("alpha", in: index) == ["Projekty/Druhé.md"])

        try await index.update(relativePaths: ["Projekty/Druhé.md"])
        #expect(try await fileIDs("omega", in: index).sorted() == ["Projekty/Druhé.md", "Projekty/Pořadí.md"])
        #expect(try await fileIDs("alpha", in: index).isEmpty)
    }

    @Test("folder and root scopes read the notes they contain again, Tags and Tag Timeline included")
    func explicitScopesIgnoreStamps() async throws {
        let index = makeIndex()
        let journal = "Journal/2026/03/2026-03-14.md"
        try pinModificationDate(journal, "Projekty/Plán.md")
        try await index.synchronize()
        let before = try await index.tagTimeline(for: "acme")
        #expect(before.first?.sections.first?.markdown == "## Kickoff Acme\nPřehled požadavků od klienta. #acme")

        try replaceKeepingStamp(journal, with: """
        # 2026-03-14

        Ráno káva.

        ## Kickoff Acme
        Přehled požadavků od klienta. #beta

        ## Retro
        Kickoff šel dobře.
        """)
        try replaceKeepingStamp("Projekty/Plán.md", with: "# Plán\ncreated: 2026-03-01\n\n## Požadavky\nPřehled a rozpisy #ACME\n")
        try await index.synchronize()
        #expect(try await index.tagTimeline(for: "acme") == before)

        try await index.update(relativePaths: ["Journal/2026"])
        #expect(try await index.tagTimeline(for: "acme").isEmpty)
        #expect(try await index.journalTags().contains("beta"))
        #expect(try await index.tagTimeline(for: "beta").first?.sections.first?.markdown
            == "## Kickoff Acme\nPřehled požadavků od klienta. #beta")
        #expect(try await fileIDs("kickoff", in: index).contains("Projekty/Plán.md"))

        try await index.update(relativePaths: [""])
        #expect(try await fileIDs("kickoff", in: index) == [journal, journal])
        #expect(try await fileIDs("rozpisy", in: index) == ["Projekty/Plán.md"])
    }

    @Test("a catch-up can reread the paths a watcher reported while skipping everything else by stamp")
    func synchronizeRereadingReportedPaths() async throws {
        let index = makeIndex()
        try vault.write("# Jedna\n\n## Řada\nalpha\n", to: "Projekty/Jedna.md")
        try vault.write("# Dva\n\n## Řada\nalpha\n", to: "Projekty/Dva.md")
        try pinModificationDate("Projekty/Jedna.md", "Projekty/Dva.md")
        try await index.synchronize()
        try replaceKeepingStamp("Projekty/Jedna.md", with: "# Jedna\n\n## Řada\nomega\n")
        try replaceKeepingStamp("Projekty/Dva.md", with: "# Dva\n\n## Řada\nomega\n")

        try await index.synchronize(rereading: ["Projekty/Jedna.md"])
        #expect(try await fileIDs("omega", in: index) == ["Projekty/Jedna.md"])
        #expect(try await fileIDs("alpha", in: index) == ["Projekty/Dva.md"])
    }

    @Test("an explicit update still forgets deleted and renamed notes and ignores files outside the Vault")
    func explicitUpdateDeletionAndRename() async throws {
        let index = makeIndex()
        try await index.synchronize()
        let root = vault.vault.rootURL
        try FileManager.default.moveItem(at: root.appending(path: "Projekty/Plán.md"), to: root.appending(path: "Projekty/Nový plán.md"))
        try await index.update(relativePaths: ["Projekty"])
        #expect(try await fileIDs("požadavky", in: index) == ["Projekty/Nový plán.md"])

        try FileManager.default.removeItem(at: root.appending(path: "Projekty/Nový plán.md"))
        try await index.update(fileAt: root.appending(path: "Projekty/Nový plán.md"))
        try await index.update(fileAt: URL(filePath: "/tmp/elsewhere.md"))
        #expect(try await fileIDs("požadavky", in: index).isEmpty)
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

    // MARK: - Tags in headings

    private func ids(_ groups: [SearchResultGroup]) -> [String] {
        groups.flatMap(\.results).map { "\($0.noteName)#\($0.ordinal)" }
    }

    private func writeHeadingTagNotes() throws {
        try vault.write("""
        # 2026-04-02 #ráno

        Úvod #ukol

        ## Porada #Acme
        Zápis z porady.

        ### Detail #beta
        hlouběji

        ## Obědy
        Bez značek.

        # Odpoledne #acme
        Odpolední část.
        """, to: "Journal/2026/04/2026-04-02.md")
        try vault.write("""
        # 2026-04-05

        ## Heading only #acme
        ## Další
        text bez značky
        """, to: "Journal/2026/04/2026-04-05.md")
        try vault.write("## Volná #ACME\ntext\n", to: "Projekty/Volná.md")
        try vault.write("# Acme\n\n## Fakta #acme\nfakt\n", to: "_brain/companies/Acme2.md")
    }

    @Test("a Tag in a heading of any level finds exactly the Section it marks")
    func headingTagsAreSearchable() async throws {
        try writeHeadingTagNotes()
        let index = makeIndex()
        try await index.synchronize()

        let acme = try await index.search(SearchQuery("#acme"))
        #expect(acme.map(\.kind) == [.dailyEntry, .freeNote, .brainNote])
        // Journal newest first; the 4-2 note has the H2 Section and the H1 Section, never the introduction.
        #expect(ids([acme[0]]) == ["2026-04-05#1", "2026-04-02#1", "2026-04-02#3", "2026-03-14#1"])
        #expect(ids([acme[1]]).sorted() == ["Plán#1", "Volná#0"])
        #expect(ids([acme[2]]) == ["Acme2#1"])

        // A deeper heading's Tag marks the enclosing H2 Section.
        #expect(ids(try await index.search(SearchQuery("#beta"))) == ["2026-04-02#1"])
    }

    @Test("introductory Tags are not propagated to later Sections")
    func introductoryTagsAreLocal() async throws {
        try writeHeadingTagNotes()
        let index = makeIndex()
        try await index.synchronize()
        #expect(ids(try await index.search(SearchQuery("#ráno"))) == ["2026-04-02#0"])
        #expect(ids(try await index.search(SearchQuery("#ukol"))) == ["2026-04-02#0"])
        #expect(try await index.search(SearchQuery("#ráno obědy")).isEmpty)
    }

    @Test("a heading-only Section matches by Tag and keeps its title, with the Tag highlighted")
    func headingOnlySection() async throws {
        try writeHeadingTagNotes()
        let index = makeIndex()
        try await index.synchronize()
        let result = try #require(try await index.search(SearchQuery("#acme")).first?.results.first)
        #expect(result.noteName == "2026-04-05")
        #expect(result.title == "Heading only #acme")
        #expect(result.snippet.text == "")
        #expect(result.highlightedTitle.parts.filter(\.isMatch).map(\.text) == ["#acme"])
        // The next Section of the same note is not marked.
        #expect(!ids(try await index.search(SearchQuery("#acme"))).contains("2026-04-05#2"))
    }

    @Test("a heading Tag combines with fulltext terms and is normalised")
    func headingTagWithTerms() async throws {
        try writeHeadingTagNotes()
        try vault.write("## Káva #Café\nx\n", to: "Projekty/Decomposed.md")
        let index = makeIndex()
        try await index.synchronize()
        #expect(ids(try await index.search(SearchQuery("#ACME zápis"))) == ["2026-04-02#1"])
        #expect(ids(try await index.search(SearchQuery("#café"))) == ["Decomposed#0"])
        #expect(ids(try await index.search(SearchQuery("#Cafe\u{301}"))) == ["Decomposed#0"])
    }

    @Test("repeating a Tag in a Section does not duplicate the Section in results")
    func repeatedTags() async throws {
        try vault.write("## A #acme #Acme\ntext #ACME\n### D #acme\n## B\n", to: "Projekty/Repeat.md")
        let index = makeIndex()
        try await index.synchronize()
        #expect(ids(try await index.search(SearchQuery("#acme")).filter { $0.kind == .freeNote }).filter { $0.hasPrefix("Repeat") } == ["Repeat#0"])
    }

    @Test("Tags in code, URLs, link targets and wiki-links of a heading do not mark the Section")
    func headingExclusions() async throws {
        try vault.write("""
        ## `#kod` [a](https://a.cz/#cil) https://b.cz/#url [[Jiná#Sekce]] C#
        text

        ## Skutečná #ano
        ```
        ## Kód #ne
        ```
        """, to: "Projekty/Vyjimky.md")
        let index = makeIndex()
        try await index.synchronize()
        for tag in ["#kod", "#cil", "#url", "#sekce", "#ne"] {
            #expect(try await index.search(SearchQuery(tag)).filter { $0.kind == .freeNote }.isEmpty, "\(tag)")
        }
        #expect(ids(try await index.search(SearchQuery("#ano"))) == ["Vyjimky#1"])
    }

    @Test("saving a heading Tag, changing it or removing it updates the index")
    func headingTagEdits() async throws {
        let index = makeIndex()
        try await index.synchronize()
        try vault.write("## Kickoff Acme #novy\nx\n", to: "Journal/2026/03/2026-03-14.md")
        try await index.update(fileAt: vault.vault.rootURL.appending(path: "Journal/2026/03/2026-03-14.md"))
        #expect(ids(try await index.search(SearchQuery("#novy"))) == ["2026-03-14#0"])
        try vault.write("## Kickoff Acme #jiny and more text\n", to: "Journal/2026/03/2026-03-14.md")
        try await index.update(fileAt: vault.vault.rootURL.appending(path: "Journal/2026/03/2026-03-14.md"))
        #expect(try await index.search(SearchQuery("#novy")).isEmpty)
        #expect(ids(try await index.search(SearchQuery("#jiny"))) == ["2026-03-14#0"])
    }

    @Test("a cache built by an older version converges on heading Tags without any edit to the notes")
    func oldCacheConverges() async throws {
        try writeHeadingTagNotes()
        // An index from before heading Tags were recognised: a previous schema version whose
        // content (and recorded file stamps) would otherwise make every note look up to date.
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = try SQLiteDatabase(url: databaseURL)
        try old.execute("CREATE TABLE files (path TEXT); PRAGMA user_version = \(SearchIndex.schemaVersion - 1);")

        let index = makeIndex()
        try await index.synchronize()
        #expect(ids(try await index.search(SearchQuery("#beta"))) == ["2026-04-02#1"])
        #expect(ids(try await index.search(SearchQuery("#acme")).filter { $0.kind == .dailyEntry })
            == ["2026-04-05#1", "2026-04-02#1", "2026-04-02#3", "2026-03-14#1"])

        // On a later start the converged cache is kept, not rebuilt again.
        let reopened = makeIndex()
        try await reopened.synchronize()
        #expect(ids(try await reopened.search(SearchQuery("#beta"))) == ["2026-04-02#1"])
    }

    // MARK: - Tag Timeline

    private func writeTimelineNotes() throws {
        try vault.write("""
        # 2026-05-03 #intro

        Úvod dne. #acme

        ## Porada #Acme
        Zápis z porady.

        ### Podrobnosti
        - [ ] úkol pro #beta
        ![schéma](attachments/schema.png)

        ## Oběd
        Bez značek, i když zmíním acme.

        ## Večer
        Hovor s klientem #ACME #acme
        """, to: "Journal/2026/05/2026-05-03.md")
        try vault.write("""
        # 2026-05-01

        ## Kickoff #acme
        \(String(repeating: "Dlouhý text bez zkrácení. ", count: 200))konec sekce
        """, to: "Journal/2026/05/2026-05-01.md")
        try vault.write("""
        # 2026-04-30

        ## Jinak #Café
        """, to: "Journal/2026/04/2026-04-30.md")
        try vault.write("## Volná #acme\ntext\n", to: "Projekty/Volná.md")
        try vault.write("# Acme\n\n## Fakta #acme #zakaznik\nfakt\n", to: "_brain/companies/Acme3.md")
    }

    private func timelineIDs(_ days: [TagTimelineDay]) -> [String] {
        days.flatMap { day in day.sections.map { "\(day.day.isoString)#\($0.ordinal)" } }
    }

    @Test("the Tag list holds each normalised Tag of saved Daily Entries once, Free Notes and Brain Notes left out")
    func journalTags() async throws {
        try writeTimelineNotes()
        let index = makeIndex()
        try await index.synchronize()
        #expect(try await index.journalTags() == ["acme", "beta", "café", "intro"])
    }

    @Test("a Tag Timeline holds the complete matching Sections, newest day first and in their order within a day")
    func tagTimeline() async throws {
        try writeTimelineNotes()
        let index = makeIndex()
        try await index.synchronize()

        let days = try await index.tagTimeline(for: "#ACME")
        #expect(days.map(\.day.isoString) == ["2026-05-03", "2026-05-01", "2026-03-14"])
        #expect(timelineIDs(days) == ["2026-05-03#0", "2026-05-03#1", "2026-05-03#3", "2026-05-01#1", "2026-03-14#1"])

        let may3 = days[0].sections
        #expect(may3.allSatisfy { $0.relativePath == "Journal/2026/05/2026-05-03.md" })
        #expect(may3[0].title == "2026-05-03 #intro")
        #expect(may3[0].markdown == "# 2026-05-03 #intro\n\nÚvod dne. #acme")
        #expect(may3[1].title == "Porada #Acme")
        #expect(may3[1].markdown == """
        ## Porada #Acme
        Zápis z porady.

        ### Podrobnosti
        - [ ] úkol pro #beta
        ![schéma](attachments/schema.png)
        """)
        #expect(may3[2].markdown == "## Večer\nHovor s klientem #ACME #acme")

        let long = try #require(days[1].sections.first)
        #expect(long.markdown.hasPrefix("## Kickoff #acme\nDlouhý text"))
        #expect(long.markdown.hasSuffix("konec sekce"))
        #expect(long.markdown.count > 5000)
    }

    @Test("a Tag Timeline matches Tags case-insensitively and Unicode-normalised, and is empty for an unknown Tag")
    func tagTimelineNormalisation() async throws {
        try writeTimelineNotes()
        let index = makeIndex()
        try await index.synchronize()
        #expect(timelineIDs(try await index.tagTimeline(for: "CAFE\u{301}")) == ["2026-04-30#1"])
        #expect(timelineIDs(try await index.tagTimeline(for: "beta")) == ["2026-05-03#1"])
        #expect(try await index.tagTimeline(for: "zakaznik").isEmpty)
        #expect(try await index.tagTimeline(for: "neexistuje").isEmpty)
    }

    @Test("the Tag Timeline shows saved content only and follows saves, outside changes and deletions")
    @MainActor
    func tagTimelineFollowsSavedContent() async throws {
        try writeTimelineNotes()
        let index = makeIndex()
        try await index.synchronize()
        let path = "Journal/2026/05/2026-05-01.md"
        let url = vault.vault.rootURL.appending(path: path)

        let document = try NoteDocument.open(fileURL: url, newFileContent: "")
        document.text = "# 2026-05-01\n\n## Kickoff #novy\nneuloženo\n"
        _ = document.stageAttachment(data: Data([0x89, 0x50]), fileExtension: "png")
        try await index.update(relativePaths: [""])
        #expect(try await index.journalTags() == ["acme", "beta", "café", "intro"])
        #expect(timelineIDs(try await index.tagTimeline(for: "acme")).contains("2026-05-01#1"))

        try document.save()
        try await index.update(fileAt: url)
        #expect(try await index.journalTags() == ["acme", "beta", "café", "intro", "novy"])
        #expect(!timelineIDs(try await index.tagTimeline(for: "acme")).contains("2026-05-01#1"))
        #expect(try await index.tagTimeline(for: "novy").first?.sections.first?.markdown == "## Kickoff #novy\nneuloženo")

        try vault.write("# 2026-04-30\n\n## Venku #novy\nzměněno mimo Notess\n", to: "Journal/2026/04/2026-04-30.md")
        try FileManager.default.removeItem(at: url)
        try await index.update(relativePaths: ["Journal/2026/04/2026-04-30.md", path])
        #expect(timelineIDs(try await index.tagTimeline(for: "novy")) == ["2026-04-30#1"])
        #expect(try await index.journalTags() == ["acme", "beta", "intro", "novy"])
    }

    @Test("reopening and rebuilding the cache reproduce the same Tag Timeline")
    func tagTimelineSurvivesReopenAndRebuild() async throws {
        try writeTimelineNotes()
        let index = makeIndex()
        try await index.synchronize()
        let tags = try await index.journalTags()
        let timeline = try await index.tagTimeline(for: "acme")

        let reopened = makeIndex()
        try await reopened.synchronize()
        #expect(try await reopened.journalTags() == tags)
        #expect(try await reopened.tagTimeline(for: "acme") == timeline)

        try await reopened.rebuild()
        #expect(try await reopened.journalTags() == tags)
        #expect(try await reopened.tagTimeline(for: "acme") == timeline)
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
