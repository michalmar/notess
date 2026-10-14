import Foundation
import Testing
@testable import NotessCore

@Suite("Wiki-link resolution")
struct WikiLinkResolverTests {
    private func resolve(_ target: String, in paths: [String]) -> String? {
        WikiLinkResolver(relativePaths: paths).resolve(target: target)
    }

    @Test("finds a note by file name anywhere in the Vault")
    func findsByName() {
        let paths = ["Acme.md", "Projekty/Beta.md", "_brain/Anna.md", "Journal/2026/03/2026-03-14.md"]
        #expect(resolve("Acme", in: paths) == "Acme.md")
        #expect(resolve("Beta", in: paths) == "Projekty/Beta.md")
        #expect(resolve("Anna", in: paths) == "_brain/Anna.md")
    }

    @Test("a date finds the Daily Entry")
    func dailyEntry() {
        let paths = ["Journal/2026/03/2026-03-14.md", "Journal/2026/03/2026-03-15.md"]
        #expect(resolve("2026-03-14", in: paths) == "Journal/2026/03/2026-03-14.md")
        #expect(resolve("2026-03-16", in: paths) == nil)
    }

    @Test("matching ignores case, whitespace, a trailing .md and Unicode normalisation")
    func lenientMatching() {
        let paths = ["Škola.md"]
        #expect(resolve("škola", in: paths) == "Škola.md")
        #expect(resolve("  Škola  ", in: paths) == "Škola.md")
        #expect(resolve("Škola.md", in: paths) == "Škola.md")
        #expect(resolve("S\u{30C}kola", in: paths) == "Škola.md")
    }

    @Test("an unknown or empty target resolves to nothing")
    func missing() {
        #expect(resolve("Nope", in: ["Acme.md"]) == nil)
        #expect(resolve("", in: ["Acme.md"]) == nil)
        #expect(resolve("   ", in: ["Acme.md"]) == nil)
    }

    @Test("files that are not notes are ignored")
    func ignoresNonNotes() {
        let paths = ["image.png", "attachments/Acme.md", ".hidden/Acme.md", "Journal/Acme.md"]
        #expect(resolve("Acme", in: paths) == nil)
        #expect(resolve("image", in: paths) == nil)
    }

    @Test("a path suffix narrows the match to that folder")
    func pathSuffix() {
        let paths = ["Acme.md", "Klienti/Acme.md", "Interní/Acme.md"]
        #expect(resolve("Klienti/Acme", in: paths) == "Klienti/Acme.md")
        #expect(resolve("interní/acme", in: paths) == "Interní/Acme.md")
        #expect(resolve("Jiné/Acme", in: paths) == nil)
    }

    @Test("an exact-case name beats a case-only match")
    func exactCaseWins() {
        let paths = ["a/acme.md", "z/Acme.md"]
        #expect(resolve("Acme", in: paths) == "z/Acme.md")
        #expect(resolve("acme", in: paths) == "a/acme.md")
        #expect(resolve("ACME", in: paths) == "a/acme.md")
    }

    @Test("duplicates: Free Note, then Daily Entry, then Brain Note")
    func kindPrecedence() {
        #expect(resolve("Anna", in: ["_brain/Anna.md", "Lidé/Anna.md"]) == "Lidé/Anna.md")
        #expect(resolve("2026-03-14", in: ["_brain/2026-03-14.md", "Journal/2026/03/2026-03-14.md"])
            == "Journal/2026/03/2026-03-14.md")
        #expect(resolve("2026-03-14", in: ["Journal/2026/03/2026-03-14.md", "Různé/2026-03-14.md"])
            == "Různé/2026-03-14.md")
    }

    @Test("duplicates: the note nearest the Vault root wins")
    func depthPrecedence() {
        let paths = ["a/b/c/Acme.md", "z/Acme.md", "x/y/Acme.md"]
        #expect(resolve("Acme", in: paths) == "z/Acme.md")
    }

    @Test("duplicates: the first path in alphabetical order wins, regardless of input order")
    func alphabeticalTieBreak() {
        let paths = ["Zeta/Acme.md", "Beta/Acme.md", "alfa/Acme.md"]
        #expect(resolve("Acme", in: paths) == "alfa/Acme.md")
        #expect(resolve("Acme", in: paths.reversed()) == "alfa/Acme.md")
        #expect(resolve("Acme", in: [paths[1], paths[2], paths[0]]) == "alfa/Acme.md")
    }

    @Test("scans the Vault for notes, skipping attachments, hidden and non-Markdown files")
    func scanNotePaths() throws {
        let temp = try TemporaryVault()
        try temp.write("", to: "Acme.md")
        try temp.write("", to: "Projekty/Beta.md")
        try temp.write("", to: "_brain/Anna.md")
        try temp.write("", to: "Journal/2026/03/2026-03-14.md")
        try temp.write("", to: "Journal/stray.md")
        try temp.write("", to: "attachments/Pic.md")
        try temp.write("", to: ".hidden/Secret.md")
        try temp.write("", to: "photo.png")
        #expect(Set(temp.vault.scanNotePaths()) == [
            "Acme.md", "Projekty/Beta.md", "_brain/Anna.md", "Journal/2026/03/2026-03-14.md",
        ])
    }

    @Test("resolves links parsed from text")
    func fromParsedLink() throws {
        let link = try #require(WikiLink.links(in: "viz [[2026-03-14#Plán]]").first)
        let resolver = WikiLinkResolver(relativePaths: ["Journal/2026/03/2026-03-14.md"])
        #expect(resolver.resolve(target: link.target) == "Journal/2026/03/2026-03-14.md")
    }
}
