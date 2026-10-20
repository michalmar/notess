import Foundation
import Testing
@testable import NotessCore

@Suite("Tag completion context")
struct TagCompletionContextTests {
    /// The context at `‸` in `marked`.
    private func context(_ marked: String) -> TagCompletionContext? {
        let caret = (marked as NSString).range(of: "‸").location
        let text = marked.replacingOccurrences(of: "‸", with: "")
        return TagCompletion.context(in: text, caret: caret)
    }

    private func prefix(_ marked: String) -> String? {
        context(marked)?.prefix
    }

    @Test("a hash and Tag-name characters before the caret form the prefix")
    func simplePrefix() throws {
        let found = try #require(context("Kickoff #ac‸"))
        #expect(found.prefix == "ac")
        #expect(found.tokenRange == NSRange(location: 8, length: 3))
        #expect(found.caret == 11)
    }

    @Test("a bare hash, a space or no hash gives no context")
    func noPrefix() {
        #expect(context("text #‸") == nil)
        #expect(context("# ‸") == nil)
        #expect(context("# Nadpis‸") == nil)
        #expect(context("plain‸") == nil)
        #expect(context("#acme ‸") == nil)
        #expect(context("‸#acme") == nil)
        #expect(context("#‸acme") == nil)
    }

    @Test("digit, hyphen and underscore prefixes count without a letter")
    func letterlessPrefixes() {
        #expect(prefix("#2‸") == "2")
        #expect(prefix("#q3-‸") == "q3-")
        #expect(prefix("#-‸") == "-")
        #expect(prefix("#_‸") == "_")
    }

    @Test("the caret inside a Tag uses hash-to-caret as prefix and the whole token as range")
    func midToken() throws {
        let found = try #require(context("x #pro‸jekt y"))
        #expect(found.prefix == "pro")
        #expect(found.tokenRange == NSRange(location: 2, length: 8))
        #expect(found.caret == 6)
    }

    @Test("the prefix is normalised for matching")
    func normalisedPrefix() throws {
        #expect(context("#ŠKo‸")?.normalizedPrefix == "ško")
        let decomposed = try #require(context("#S\u{30C}k‸"))
        #expect(decomposed.normalizedPrefix == "šk")
        #expect(decomposed.prefix == "S\u{30C}k")
    }

    @Test("Tags in headings, lists, quotes, emphasis, link text and table cells are eligible")
    func allowedContexts() {
        #expect(prefix("## Porada #ac‸") == "ac")
        #expect(prefix("- úkol #ac‸") == "ac")
        #expect(prefix("> citát #ac‸") == "ac")
        #expect(prefix("**#ac‸**") == "ac")
        #expect(prefix("[#ac‸](https://example.com)") == "ac")
        #expect(prefix("| A | B |\n| - | - |\n| #ac‸ | x |") == "ac")
        #expect(prefix("(#ac‸)") == "ac")
        #expect(prefix("#ac‸ další") == "ac")
    }

    @Test("excluded contexts give no completion")
    func excludedContexts() {
        #expect(context("C#ac‸") == nil)
        #expect(context("page#sec‸") == nil)
        #expect(context("`#ac‸`") == nil)
        #expect(context("```\n#ac‸\n```") == nil)
        #expect(context("    #ac‸") == nil)
        #expect(context("[text](https://example.com/#ac‸)") == nil)
        #expect(context("https://example.com/#ac‸") == nil)
        #expect(context("[[Note#ac‸]]") == nil)
        #expect(context("[[#ac‸]]") == nil)
        #expect(context("\\#ac‸") == nil)
        #expect(context("---\ntags: #ac‸\n---\ntext") == nil)
    }

    @Test("a caret in the middle of a surrogate pair gives no context")
    func surrogateSplit() {
        let text = "#a😀"
        #expect(TagCompletion.context(in: text, caret: 3) == nil)
    }

    @Test("carets outside the text give no context")
    func outOfRange() {
        #expect(TagCompletion.context(in: "#acme", caret: -1) == nil)
        #expect(TagCompletion.context(in: "#acme", caret: 6) == nil)
    }

    @Test("Tag recognition is unchanged: letterless names are still not Tags")
    func recognitionUnchanged() {
        #expect(Tag.tags(in: "#2026 #- #_").isEmpty)
    }
}

@Suite("Tag completion candidates")
struct TagCompletionCandidatesTests {
    private let vocabulary = ["acme", "akce", "projekt", "projekty", "2026-plan", "škola", "_draft", "-x"]

    @Test("candidates are prefix matches, sorted, without the typed name itself")
    func prefixMatches() {
        #expect(TagCompletion.candidates(matching: "a", in: vocabulary) == ["acme", "akce"])
        #expect(TagCompletion.candidates(matching: "projekt", in: vocabulary) == ["projekty"])
        #expect(TagCompletion.candidates(matching: "projekty", in: vocabulary).isEmpty)
        #expect(TagCompletion.candidates(matching: "2", in: vocabulary) == ["2026-plan"])
        #expect(TagCompletion.candidates(matching: "_", in: vocabulary) == ["_draft"])
        #expect(TagCompletion.candidates(matching: "-", in: vocabulary) == ["-x"])
    }

    @Test("matching is case-insensitive and Unicode-normalised, without diacritic folding")
    func normalisation() {
        #expect(TagCompletion.candidates(matching: "AK", in: vocabulary) == ["akce"])
        #expect(TagCompletion.candidates(matching: "Š", in: vocabulary) == ["škola"])
        #expect(TagCompletion.candidates(matching: "S\u{30C}k", in: vocabulary) == ["škola"])
        #expect(TagCompletion.candidates(matching: "s", in: vocabulary).isEmpty)
    }

    @Test("no fuzzy or substring matches")
    func noSubstring() {
        #expect(TagCompletion.candidates(matching: "cme", in: vocabulary).isEmpty)
        #expect(TagCompletion.candidates(matching: "pjt", in: vocabulary).isEmpty)
    }

    @Test("vocabulary entries are normalised and deduplicated")
    func deduplicated() {
        let raw = ["Acme", "ACME", "acme", "#Akce", "akce"]
        #expect(TagCompletion.candidates(matching: "a", in: raw) == ["acme", "akce"])
    }

    @Test("an empty prefix has no candidates")
    func emptyPrefix() {
        #expect(TagCompletion.candidates(matching: "", in: vocabulary).isEmpty)
        #expect(TagCompletion.candidates(matching: "#", in: vocabulary).isEmpty)
    }

    @Test("there is no result cutoff")
    func noCutoff() {
        let many = (0..<50).map { "tag\($0)" }
        #expect(TagCompletion.candidates(matching: "tag", in: many).count == 50)
    }
}
