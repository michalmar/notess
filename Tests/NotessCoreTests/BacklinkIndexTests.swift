import Foundation
import Synchronization
import Testing
@testable import NotessCore

/// Counts how often each note text is parsed.
private final class ParseCounter: Sendable {
    private let counts = Mutex<[String: Int]>([:])

    var total: Int { counts.withLock { $0.values.reduce(0, +) } }

    func count(_ text: String) -> Int { counts.withLock { $0[text] ?? 0 } }

    func reset() { counts.withLock { $0 = [:] } }

    func makeIndex() -> BacklinkIndex {
        BacklinkIndex(tokenize: { text in
            self.counts.withLock { $0[text, default: 0] += 1 }
            return MarkdownSyntax.tokens(in: text)
        })
    }
}

@Suite("Backlink index")
struct BacklinkIndexTests {
    @Test("rebuild finds resolved links from every note kind and groups them by source Section")
    func rebuildFindsResolvedLinks() async throws {
        let temp = try TemporaryVault()
        try temp.write("# Acme\n", to: "Acme.md")
        try temp.write("# Acme duplicate\n", to: "_brain/Acme.md")
        try temp.write(
            """
            # 2026-03-14

            ## Plán
            Domluvit další krok s [[Acme]].
            [[Acme#Kontakty]]
            """,
            to: "Journal/2026/03/2026-03-14.md"
        )
        try temp.write(
            """
            # Projekt

            ## Kontext
            Brain Note odkazuje na [[Acme]].
            """,
            to: "_brain/projects/Projekt.md"
        )

        let index = BacklinkIndex()
        await index.rebuild(in: temp.vault)

        let backlinks = await index.backlinks(to: "Acme.md")
        #expect(backlinks.count == 2)
        #expect(backlinks.map(\.sourceRelativePath) == [
            "_brain/projects/Projekt.md",
            "Journal/2026/03/2026-03-14.md",
        ])
        #expect(backlinks.map(\.sectionTitle) == ["Kontext", "Plán"])
        #expect(backlinks[1].preview == "Domluvit další krok s [[Acme]]. [[Acme#Kontakty]]")
        #expect(await index.backlinks(to: "_brain/Acme.md").isEmpty)
    }

    @Test("update replaces saved content and removes deleted notes")
    func updateAfterSaveAndDeletion() async throws {
        let temp = try TemporaryVault()
        try temp.write("# Acme\n", to: "Acme.md")
        try temp.write("# Beta\n", to: "Beta.md")
        try temp.write("## Stav\nOdkaz na [[Acme]].", to: "Zdroj.md")
        let index = BacklinkIndex()
        await index.rebuild(in: temp.vault)

        try temp.write("## Stav\nOdkaz na [[Beta]].", to: "Zdroj.md")
        await index.update(relativePath: "Zdroj.md", content: "## Stav\nOdkaz na [[Beta]].", in: temp.vault)

        #expect(await index.backlinks(to: "Acme.md").isEmpty)
        #expect(await index.backlinks(to: "Beta.md").map(\.sourceRelativePath) == ["Zdroj.md"])

        try FileManager.default.removeItem(at: temp.vault.rootURL.appending(path: "Zdroj.md"))
        await index.update(relativePath: "Zdroj.md", content: nil, in: temp.vault)
        #expect(await index.backlinks(to: "Beta.md").isEmpty)
    }

    @Test("one source Section can link to several targets but appears once for each target")
    func sectionLinksToSeveralTargets() async throws {
        let temp = try TemporaryVault()
        try temp.write("", to: "Acme.md")
        try temp.write("", to: "Beta.md")
        try temp.write("## Stav\n[[Acme]] a [[Beta]] a znovu [[Acme]].", to: "Zdroj.md")
        let index = BacklinkIndex()

        await index.rebuild(in: temp.vault)

        #expect(await index.backlinks(to: "Acme.md").count == 1)
        #expect(await index.backlinks(to: "Beta.md").count == 1)
    }

    @Test("duplicate Section titles retain their exact source heading ranges")
    func duplicateSectionTitles() async throws {
        let temp = try TemporaryVault()
        try temp.write("", to: "Acme.md")
        let source = "## Stav\nprvní\n\n## Stav\ndruhý [[Acme]]"
        try temp.write(source, to: "Zdroj.md")
        let index = BacklinkIndex()

        await index.rebuild(in: temp.vault)

        let backlink = try #require(await index.backlinks(to: "Acme.md").first)
        let range = try #require(backlink.sectionHeadingRange)
        #expect((source as NSString).substring(with: range) == "## Stav")
        #expect(range.location == 15)
        #expect(backlink.sectionTitleOccurrence == 1)
    }

    @Test("same-note Section links are not backlinks")
    func ignoresSameNoteSectionLinks() async throws {
        let temp = try TemporaryVault()
        try temp.write("## První\n[[#Druhá]]\n\n## Druhá\ntext", to: "Acme.md")
        let index = BacklinkIndex()

        await index.rebuild(in: temp.vault)

        #expect(await index.backlinks(to: "Acme.md").isEmpty)
    }

    // MARK: Incremental updates

    private func move(_ from: String, to: String, in temp: TemporaryVault) throws {
        let root = temp.vault.rootURL
        let destination = root.appending(path: to)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: root.appending(path: from), to: destination)
    }

    private func remove(_ path: String, in temp: TemporaryVault) throws {
        try FileManager.default.removeItem(at: temp.vault.rootURL.appending(path: path))
    }

    /// Every note's backlinks, to compare an index with a fresh rebuild.
    private func snapshot(of index: BacklinkIndex, in vault: Vault) async -> [String: [Backlink]] {
        var result: [String: [Backlink]] = [:]
        for path in vault.scanNotePaths() {
            let backlinks = await index.backlinks(to: path)
            if !backlinks.isEmpty { result[path] = backlinks }
        }
        return result
    }

    private func rebuilt(_ vault: Vault) async -> [String: [Backlink]] {
        let index = BacklinkIndex()
        await index.rebuild(in: vault)
        return await snapshot(of: index, in: vault)
    }

    @Test("saving one note parses only that note, once, sharing tokens between Sections and Wiki-links")
    func contentUpdateParsesOnlyThatSource() async throws {
        let temp = try TemporaryVault()
        try temp.write("# Acme\n", to: "Acme.md")
        try temp.write("## A\n[[Acme]]", to: "A.md")
        try temp.write("## B\n[[Acme]]", to: "B.md")
        let counter = ParseCounter()
        let index = counter.makeIndex()
        await index.rebuild(in: temp.vault)
        #expect(counter.total == 3)
        counter.reset()

        let saved = "## A nově\nOdkaz na [[Acme]] a [[B]]."
        try temp.write(saved, to: "A.md")
        await index.update(relativePath: "A.md", content: saved, in: temp.vault)

        #expect(counter.total == 1)
        #expect(counter.count(saved) == 1)
        #expect(await index.backlinks(to: "Acme.md").map(\.sectionTitle) == ["A nově", "B"])
        #expect(await index.backlinks(to: "B.md").map(\.sourceRelativePath) == ["A.md"])
        #expect(await snapshot(of: index, in: temp.vault) == (await rebuilt(temp.vault)))
    }

    @Test("rereading unchanged files after a watcher event parses nothing")
    func unchangedRereadParsesNothing() async throws {
        let temp = try TemporaryVault()
        try temp.write("# Acme\n", to: "Acme.md")
        try temp.write("## A\n[[Acme]]", to: "Notes/A.md")
        let counter = ParseCounter()
        let index = counter.makeIndex()
        await index.rebuild(in: temp.vault)
        counter.reset()

        await index.update(changedPaths: [""], in: temp.vault)
        await index.update(changedPaths: ["Notes"], in: temp.vault)
        await index.update(changedPaths: ["Notes/A.md"], in: temp.vault)

        #expect(counter.total == 0)
        #expect(await index.backlinks(to: "Acme.md").count == 1)
    }

    @Test("a watcher event rereads only the changed file or folder")
    func watcherChangeRereadsScope() async throws {
        let temp = try TemporaryVault()
        try temp.write("# Acme\n", to: "Acme.md")
        try temp.write("## A\n[[Acme]]", to: "Notes/A.md")
        try temp.write("## B\n[[Acme]]", to: "Other/B.md")
        let counter = ParseCounter()
        let index = counter.makeIndex()
        await index.rebuild(in: temp.vault)
        counter.reset()
        try temp.write("## A2\n[[Acme]]", to: "Notes/A.md")
        try temp.write("## B2\n[[Acme]]", to: "Other/B.md")

        await index.update(changedPaths: ["Notes"], in: temp.vault)

        #expect(counter.total == 1)
        #expect(await index.backlinks(to: "Acme.md").map(\.sectionTitle) == ["A2", "B"])
    }

    @Test("adding, deleting and renaming a source note parses only the new file")
    func sourceAddDeleteRename() async throws {
        let temp = try TemporaryVault()
        try temp.write("# Acme\n", to: "Acme.md")
        try temp.write("## A\n[[Acme]]", to: "A.md")
        let counter = ParseCounter()
        let index = counter.makeIndex()
        await index.rebuild(in: temp.vault)
        counter.reset()

        try temp.write("## Nový\n[[Acme]]", to: "Notes/New.md")
        await index.update(changedPaths: ["Notes/New.md"], in: temp.vault)
        #expect(counter.total == 1)
        #expect(await index.backlinks(to: "Acme.md").map(\.sourceRelativePath) == ["A.md", "Notes/New.md"])

        counter.reset()
        try move("Notes/New.md", to: "Archive/Renamed.md", in: temp)
        await index.update(changedPaths: ["Notes/New.md", "Archive/Renamed.md"], in: temp.vault)
        #expect(counter.total == 1)
        #expect(await index.backlinks(to: "Acme.md").map(\.sourceRelativePath) == ["A.md", "Archive/Renamed.md"])

        counter.reset()
        try remove("A.md", in: temp)
        await index.update(changedPaths: ["A.md"], in: temp.vault)
        #expect(counter.total == 0)
        #expect(await index.backlinks(to: "Acme.md").map(\.sourceRelativePath) == ["Archive/Renamed.md"])
        #expect(await snapshot(of: index, in: temp.vault) == (await rebuilt(temp.vault)))
    }

    @Test("new, deleted and renamed duplicate-name targets redirect existing links without parsing their sources")
    func duplicateTargetsRedirect() async throws {
        let temp = try TemporaryVault()
        try temp.write("# Brain\n", to: "_brain/Acme.md")
        let source = "## Plán\n[[Acme]]"
        try temp.write(source, to: "Journal/2026/03/2026-03-14.md")
        let exactSource = "## Stav\n[[note]]"
        try temp.write(exactSource, to: "Zdroj.md")
        try temp.write("", to: "B/Note.md")
        let counter = ParseCounter()
        let index = counter.makeIndex()
        await index.rebuild(in: temp.vault)
        #expect(await index.backlinks(to: "_brain/Acme.md").count == 1)

        // A Free Note beats a Brain Note.
        try temp.write("", to: "Projects/Deep/Acme.md")
        await index.update(changedPaths: ["Projects"], in: temp.vault)
        #expect(await index.backlinks(to: "_brain/Acme.md").isEmpty)
        #expect(await index.backlinks(to: "Projects/Deep/Acme.md").count == 1)

        // Fewer folders win.
        try temp.write("", to: "Projects/Acme.md")
        await index.update(changedPaths: ["Projects/Acme.md"], in: temp.vault)
        #expect(await index.backlinks(to: "Projects/Deep/Acme.md").isEmpty)
        #expect(await index.backlinks(to: "Projects/Acme.md").count == 1)

        // Renaming the winner away hands the links back to the next one.
        try move("Projects/Acme.md", to: "Projects/Other.md", in: temp)
        await index.update(changedPaths: ["Projects/Acme.md", "Projects/Other.md"], in: temp.vault)
        #expect(await index.backlinks(to: "Projects/Deep/Acme.md").count == 1)

        // Deleting the last Free Note falls back to the Brain Note.
        try remove("Projects/Deep/Acme.md", in: temp)
        await index.update(changedPaths: ["Projects/Deep"], in: temp.vault)
        #expect(await index.backlinks(to: "_brain/Acme.md").count == 1)

        // The exact-case name beats a case-only match nearer the root; then alphabetical order.
        #expect(await index.backlinks(to: "B/Note.md").count == 1)
        try temp.write("", to: "C/note.md")
        await index.update(changedPaths: ["C/note.md"], in: temp.vault)
        #expect(await index.backlinks(to: "C/note.md").count == 1)
        try temp.write("", to: "A/note.md")
        await index.update(changedPaths: ["A/note.md"], in: temp.vault)
        #expect(await index.backlinks(to: "C/note.md").isEmpty)
        #expect(await index.backlinks(to: "A/note.md").count == 1)

        #expect(counter.count(source) == 1)
        #expect(counter.count(exactSource) == 1)
        #expect(await snapshot(of: index, in: temp.vault) == (await rebuilt(temp.vault)))
    }

    @Test("a note that cannot be read drops out until it can be read again")
    func unreadableNoteDropsOut() async throws {
        let temp = try TemporaryVault()
        try temp.write("# Acme\n", to: "Acme.md")
        try temp.write("## A\n[[Acme]]", to: "A.md")
        let index = BacklinkIndex()
        await index.rebuild(in: temp.vault)

        try Data([0xFF, 0xFE, 0xFD]).write(to: temp.vault.rootURL.appending(path: "A.md"))
        await index.update(changedPaths: ["A.md"], in: temp.vault)
        #expect(await index.backlinks(to: "Acme.md").isEmpty)

        try temp.write("## A\n[[Acme]]", to: "A.md")
        await index.update(changedPaths: [], in: temp.vault)
        #expect(await index.backlinks(to: "Acme.md").count == 1)
    }

    @Test("a long series of incremental updates matches a full rebuild")
    func incrementalMatchesRebuild() async throws {
        let temp = try TemporaryVault()
        try temp.write("# Acme\n## Kontakty\n[[Beta]]", to: "Acme.md")
        try temp.write("## Stav\n[[Acme]] [[Beta#X]]\n## Stav\n[[acme]]", to: "Notes/Zdroj.md")
        try temp.write("## Plán\n[[Notes/Zdroj]] a [[Acme#Kontakty]]", to: "Journal/2026/03/2026-03-14.md")
        let index = BacklinkIndex()
        await index.rebuild(in: temp.vault)

        try temp.write("", to: "Beta.md")
        try temp.write("## Nový\n[[Zdroj]] `[[Acme]]`", to: "_brain/Beta.md")
        await index.update(changedPaths: [""], in: temp.vault)
        #expect(await snapshot(of: index, in: temp.vault) == (await rebuilt(temp.vault)))

        let saved = "## Jiný\n[[Beta]]\n```\n[[Acme]]\n```"
        try temp.write(saved, to: "Notes/Zdroj.md")
        await index.update(relativePath: "Notes/Zdroj.md", content: saved, in: temp.vault)
        try move("Acme.md", to: "Archive/Acme.md", in: temp)
        try remove("Beta.md", in: temp)
        await index.update(changedPaths: ["Acme.md", "Archive", "Beta.md"], in: temp.vault)
        #expect(await snapshot(of: index, in: temp.vault) == (await rebuilt(temp.vault)))
        #expect(await index.backlinks(to: "_brain/Beta.md").map(\.sourceRelativePath) == ["Archive/Acme.md", "Notes/Zdroj.md"])
    }

    @Test("queued updates merge: paths union, a later save wins, a rebuild sticks")
    func updatesMerge() async throws {
        var update = BacklinkIndex.Update(changedPaths: ["A.md"], savedContents: ["B.md": "old"])
        update.merge(BacklinkIndex.Update(changedPaths: ["Notes"], savedContents: ["B.md": "new"]))
        #expect(update == BacklinkIndex.Update(changedPaths: ["A.md", "Notes"], savedContents: ["B.md": "new"]))
        update.merge(BacklinkIndex.Update(rebuild: true))
        update.merge(BacklinkIndex.Update())
        #expect(update.rebuild)
        #expect(BacklinkIndex.Update().isEmpty)

        let temp = try TemporaryVault()
        try temp.write("", to: "Acme.md")
        try temp.write("## A\n[[Acme]]", to: "A.md")
        let counter = ParseCounter()
        let index = counter.makeIndex()
        await index.apply(BacklinkIndex.Update(rebuild: true), in: temp.vault)
        await index.apply(BacklinkIndex.Update(), in: temp.vault)
        #expect(counter.total == 2)
        #expect(await index.backlinks(to: "Acme.md").count == 1)
    }
}
