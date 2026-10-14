import Foundation
import Testing
@testable import NotessCore

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
}
