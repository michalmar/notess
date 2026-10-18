import Foundation
import Testing
@testable import NotessCore

@MainActor
struct FreeNoteTests {
    @Test func fileStemKeepsDiacriticsAndRemovesUnsafeCharacters() {
        #expect(FreeNote.fileStem(forTitle: "Příliš žluťoučký kůň") == "Příliš žluťoučký kůň")
        #expect(FreeNote.fileStem(forTitle: "a/b: c\\d") == "a b c d")
        #expect(FreeNote.fileStem(forTitle: "  ..skryté  ") == "skryté")
        #expect(FreeNote.fileStem(forTitle: String(repeating: "x", count: 300)).count == 100)
    }

    @Test func emptyTitleFallsBackToDefaultName() {
        #expect(FreeNote.fileStem(forTitle: nil) == "Bez názvu")
        #expect(FreeNote.fileStem(forTitle: "  / ") == "Bez názvu")
    }

    @Test func titleSkipsFrontMatter() {
        let text = "---\ncreated: 2026-03-14\n---\n\n# Nápad\n\ntext"
        #expect(FreeNote.title(in: text) == "Nápad")
        #expect(FreeNote.title(in: "---\ncreated: x\n---\n\n# ") == "")
        #expect(FreeNote.title(in: "bez nadpisu") == nil)
    }

    @Test func initialContentHasFrontMatterAndHeading() {
        let content = FreeNote.initialContent(createdOn: Day(year: 2026, month: 3, day: 4))
        #expect(content == "---\ncreated: 2026-03-04\n---\n\n# ")
    }

    @Test func collisionAddsNumericSuffix() throws {
        let tmp = try TemporaryVault()
        try tmp.write("x", to: "Nápad.md")
        try tmp.write("x", to: "Nápad 2.md")
        let url = FreeNote.availableURL(inFolder: tmp.vault.rootURL, stem: "Nápad")
        #expect(url.lastPathComponent == "Nápad 3.md")
    }

    @Test func firstSaveCreatesFileNamedFromTitleInSelectedFolder() throws {
        let tmp = try TemporaryVault()
        let note = try tmp.vault.newFreeNote(inFolder: "Projekty", on: Day(year: 2026, month: 3, day: 4))
        #expect(!tmp.fileExists("Projekty"))
        note.text += "Můj nápad\n"
        try note.save()
        #expect(try tmp.read("Projekty/Můj nápad.md").contains("# Můj nápad"))
        #expect(note.fileURL.lastPathComponent == "Můj nápad.md")
        note.text += "víc"
        try note.save()
        #expect(note.fileURL.lastPathComponent == "Můj nápad.md")
    }

    @Test func saveDoesNotOverwriteExistingFile() throws {
        let tmp = try TemporaryVault()
        try tmp.write("původní", to: "Nápad.md")
        let note = try tmp.vault.newFreeNote(inFolder: "", on: Day(year: 2026, month: 3, day: 4))
        note.text += "Nápad"
        try note.save()
        #expect(try tmp.read("Nápad.md") == "původní")
        #expect(tmp.fileExists("Nápad 2.md"))
    }

    @Test func emptyTitleSavesUnderDefaultName() throws {
        let tmp = try TemporaryVault()
        let note = try tmp.vault.newFreeNote(inFolder: "", on: Day(year: 2026, month: 3, day: 4))
        #expect(note.displayName == "Bez názvu")
        try note.save()
        #expect(tmp.fileExists("Bez názvu.md"))
    }

    @Test func cannotCreateInJournalOrBrain() throws {
        let tmp = try TemporaryVault()
        let day = Day(year: 2026, month: 3, day: 4)
        for folder in ["Journal", "Journal/2026", "_brain", "_brain/x", "../out", "attachments"] {
            #expect(throws: FreeNoteError.reservedFolder) {
                try tmp.vault.newFreeNote(inFolder: folder, on: day)
            }
        }
    }
}

/// `main`'s eager implementation, kept verbatim as the oracle for the
/// short-circuit version. Any difference from it is a regression.
private func legacyTitle(in text: String) -> String? {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
    if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
        lines = Array(lines[(end + 1)...])
    }
    for line in lines {
        if line.hasPrefix("# ") || line == "#" {
            return String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces)
        }
    }
    return nil
}

/// Passes through its base iterator and counts how many elements were requested.
private struct CountingLines<Base: IteratorProtocol>: IteratorProtocol {
    var base: Base
    private(set) var reads = 0

    mutating func next() -> Base.Element? {
        reads += 1
        return base.next()
    }
}

/// Deterministic linear congruential generator so the random corpus is reproducible.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

private let titleCorpusTokens = [
    "---", "...", "# ", "#", "#\t", "## ", "# x ##", "# Title #", "x", " ", "\t",
    "\r", "\n", "\r\n", "```", "===", "é", "Nadpis", "| a | b |", "- # item",
]

@MainActor
struct FreeNoteTitleCharacterizationTests {
    @Test func pinsMainForChangedCases() {
        // Unclosed front-matter: the block is not stripped, so headings inside it count.
        #expect(FreeNote.title(in: "---\n# Nadpis\ntext") == "Nadpis")
        #expect(FreeNote.title(in: "---\ncreated: x\n# Později") == "Později")
        #expect(FreeNote.title(in: "---\ncreated: x\n...\n# Hlava") == "Hlava")
        #expect(FreeNote.title(in: "---\n# Meta\n---\n") == nil)
        #expect(FreeNote.title(in: "---\n# A\n---\n# B\n---\n# C") == "B")
        #expect(FreeNote.title(in: "---\n---\n# Po prázdném") == "Po prázdném")
        #expect(FreeNote.title(in: "---") == nil)

        // CRLF: a `\r\n` pair is one Character, so it is not split and stays in the title.
        #expect(FreeNote.title(in: "---\r\ncreated: x\r\n---\r\n\r\n# Nápad\r\n\r\ntext") == nil)
        #expect(FreeNote.title(in: "# Nápad\r\ntext") == "Nápad\r\ntext")
        #expect(FreeNote.title(in: "x\r\n# Hlava") == nil)
        #expect(FreeNote.title(in: "---\r\nfoo\n---\n# H") == "H")
        #expect(FreeNote.title(in: "---\r\ncreated: x\r\n---\r\n\r\n# ") == nil)

        // Setext headings and fenced code are not special.
        #expect(FreeNote.title(in: "Nadpis\n======\ntext") == nil)
        #expect(FreeNote.title(in: "```\n# kód\n```\n# Skutečný") == "kód")

        // Closing hashes are kept; only surrounding whitespace is trimmed.
        #expect(FreeNote.title(in: "# Title ##") == "Title ##")
        #expect(FreeNote.title(in: "# Title #") == "Title #")
        #expect(FreeNote.title(in: "# Nadpis   ") == "Nadpis")
        #expect(FreeNote.title(in: "#  Double") == "Double")

        // ATX-only rules: a tab, no space, or indentation does not start a heading.
        #expect(FreeNote.title(in: "#\ttab") == nil)
        #expect(FreeNote.title(in: "#Bez mezery") == nil)
        #expect(FreeNote.title(in: "    # indented") == nil)
        #expect(FreeNote.title(in: "- # list") == nil)
        #expect(FreeNote.title(in: "#") == "")
        #expect(FreeNote.title(in: "#\ntext") == "")
        #expect(FreeNote.title(in: "") == nil)
    }

    @Test func pinsMainForFirstSaveFileStems() {
        // The display name and first-save file name both come from `title(in:)`.
        #expect(FreeNote.fileStem(forTitle: FreeNote.title(in: "# Title #")) == "Title #")
        #expect(FreeNote.fileStem(forTitle: FreeNote.title(in: "---\r\nfoo\n---\n# H")) == "H")
        #expect(FreeNote.fileStem(forTitle: FreeNote.title(in: "---\n# Meta\n---\n")) == "Bez názvu")
        #expect(FreeNote.fileStem(forTitle: FreeNote.title(in: "x\r\n# Hlava")) == "Bez názvu")
    }

    @Test func matchesMainOnFixedCorpus() {
        let corpus = [
            "", "---", "#", "# ", "# x", "##x", "x\n# Hlava", "# Hlava\n# Druhá",
            "---\nfoo\n---\n# H", "---\nfoo\n# H\n---\n# I", "---\n# A\n---\n# B\n---\n# C",
            "---\n\n---\n\n#", "---\r\n---\r\n# Nadpis", "---\r\n# Nadpis\r\n---\r\n# Druhý",
            "a\r", "# \r", "#\r\n", "x\r\r\n# Hlava", "\r", "\r\n", "\n\n\n# Po prázdných",
        ]
        for text in corpus {
            #expect(FreeNote.title(in: text) == legacyTitle(in: text), "\(text.debugDescription)")
        }
    }

    @Test func matchesMainOnSeededRandomCorpus() {
        var generator = SeededGenerator(state: 45)
        for _ in 0..<5_000 {
            let count = Int.random(in: 0...14, using: &generator)
            let text = (0..<count)
                .map { _ in titleCorpusTokens.randomElement(using: &generator)! }
                .joined()
            #expect(FreeNote.title(in: text) == legacyTitle(in: text), "\(text.debugDescription)")
        }
    }

    @Test func stopsAtFirstHeadingWithoutReadingRest() {
        var lines = CountingLines(base: (["# Hlava"] + Array(repeating: "x", count: 10_000)).makeIterator())
        #expect(FreeNote.title(scanning: &lines) == "Hlava")
        #expect(lines.reads == 1)
    }

    @Test func stopsAtHeadingAfterClosedFrontMatter() {
        let lines = ["---", "created: x", "---", "", "# Nadpis"] + Array(repeating: "x", count: 10_000)
        var counting = CountingLines(base: lines.makeIterator())
        #expect(FreeNote.title(scanning: &counting) == "Nadpis")
        #expect(counting.reads == 5)
    }

    @Test func unclosedFrontMatterReadsToEnd() {
        // Without a closer, the heading is only a candidate until EOF proves no closer exists.
        let lines = ["---", "created: x", "# Později"] + Array(repeating: "x", count: 100)
        var counting = CountingLines(base: lines.makeIterator())
        #expect(FreeNote.title(scanning: &counting) == "Později")
        #expect(counting.reads == lines.count + 1)
    }
}
