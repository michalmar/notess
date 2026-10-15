import Foundation
import Testing
@testable import NotessCore

@Suite("Incremental Markdown lexing")
struct MarkdownLexerIncrementalTests {
    /// Mirrors what the editor does: keeps all tokens, and after each edit
    /// replaces the tokens of the returned range with the update's tokens.
    private struct Mirror {
        let lexer = MarkdownLexer()
        var text: NSMutableString
        var tokens: [MarkdownToken]

        init(_ text: String) {
            self.text = NSMutableString(string: text)
            tokens = lexer.reset(text: self.text)
        }

        @discardableResult
        mutating func replace(_ range: NSRange, with string: String) -> NSRange {
            text.replaceCharacters(in: range, with: string)
            let length = (string as NSString).length
            let delta = length - range.length
            let update = lexer.update(
                text: text,
                editedRange: NSRange(location: range.location, length: length),
                changeInLength: delta
            )
            let oldStart = update.range.location
            let oldEnd = update.range.upperBound - delta
            tokens = tokens.compactMap { token in
                if token.range.upperBound <= oldStart { return token }
                if token.range.location >= oldEnd {
                    var shifted = token
                    shifted.range.location += delta
                    return shifted
                }
                return nil
            } + update.tokens
            return update.range
        }

        func expectMatchesFullLex(sourceLocation: SourceLocation = #_sourceLocation) {
            let fresh = MarkdownLexer().reset(text: text)
            #expect(Set(tokens) == Set(fresh), "text: \(text.debugDescription)", sourceLocation: sourceLocation)
        }
    }

    @Test("typing in a paragraph re-lexes only that line and the one before")
    func smallRange() {
        let lines = (0..<5000).map { "Řádek \($0) s **tučným** textem a #tagem" }
        var mirror = Mirror(lines.joined(separator: "\n"))
        let location = (mirror.text as NSString).range(of: "Řádek 2500").location
        let range = mirror.replace(NSRange(location: location, length: 0), with: "x")
        #expect(range.location == (mirror.text as NSString).range(of: "Řádek 2499").location)
        #expect(range.length < 100)
        mirror.expectMatchesFullLex()
    }

    @Test("opening a code fence restyles the rest; closing it converges")
    func fenceConvergence() {
        var mirror = Mirror("a #x\n\nb #y\n\nc #z\n")
        mirror.replace(NSRange(location: 5, length: 0), with: "```\n")
        mirror.expectMatchesFullLex()
        #expect(mirror.tokens.filter { $0.kind == .tag }.count == 1)
        mirror.replace(NSRange(location: 15, length: 0), with: "```\n")
        mirror.expectMatchesFullLex()
        #expect(mirror.tokens.filter { $0.kind == .tag }.count == 2)
    }

    @Test("adding and removing a Tag in a heading converges with a full lex")
    func headingTag() {
        var mirror = Mirror("# Den\n\n## Porada\ntext\n")
        mirror.replace(NSRange(location: 16, length: 0), with: " #acme")
        mirror.expectMatchesFullLex()
        #expect(mirror.tokens.filter { $0.kind == .tag }.count == 1)
        mirror.replace(NSRange(location: 16, length: 6), with: "")
        mirror.expectMatchesFullLex()
        #expect(mirror.tokens.allSatisfy { $0.kind != .tag })
    }

    @Test("editing a table delimiter row restyles the header above")
    func tableHeader() {
        var mirror = Mirror("| a | b |\n| - | x |\n| c | d |")
        #expect(mirror.tokens.allSatisfy { $0.kind != .tableHeader })
        mirror.replace(NSRange(location: 16, length: 1), with: "-")
        mirror.expectMatchesFullLex()
        #expect(mirror.tokens.contains { $0.kind == .tableHeader })
    }

    @Test("typing a setext underline restyles the line above")
    func setext() {
        var mirror = Mirror("Titulek\n")
        mirror.replace(NSRange(location: 8, length: 0), with: "=")
        mirror.expectMatchesFullLex()
        #expect(mirror.tokens.contains { $0.kind == .heading(level: 1) })
    }

    @Test("joining and splitting lines")
    func joinSplit() {
        var mirror = Mirror("# A\n**b**\n- [ ] c\n")
        mirror.replace(NSRange(location: 3, length: 1), with: "")
        mirror.expectMatchesFullLex()
        mirror.replace(NSRange(location: 3, length: 0), with: "\n\n")
        mirror.expectMatchesFullLex()
        mirror.replace(NSRange(location: 0, length: (mirror.text as NSString).length), with: "")
        mirror.expectMatchesFullLex()
        mirror.replace(NSRange(location: 0, length: 0), with: "```\nx\n")
        mirror.expectMatchesFullLex()
    }

    @Test("random edits always match a full re-lex", arguments: 0..<20)
    func randomEdits(seed: UInt64) {
        var random = SplitMix64(seed: seed)
        let fragments = [
            "\n", "\n\n", "# ", "## Sekce", "```", "```\n", "~~~\n", "    ", "- ", "- [ ] ", "- [x] ", "1. ",
            "> ", "| a | b |\n", "| --- | --- |\n", "|", "---", "===", "**", "*", "_", "~~", "`", "[[", "]]",
            "[t](u)", "#tag", "#", "č", "😀", "slovo ", "https://a.cz ", "\r\n", "\\",
        ]
        var mirror = Mirror("---\ntitle: x\n---\n# Den\n\n## Porada #acme\n- [ ] úkol [[Jan#Kontakt]]\n\n```\n#ne\n```\n")
        for _ in 0..<200 {
            let length = (mirror.text as NSString).length
            let location = Int(random.next() % UInt64(length + 1))
            let removable = min(length - location, Int(random.next() % 6))
            let removeLength = random.next() % 3 == 0 ? removable : 0
            let insert = random.next() % 4 == 0 ? "" : fragments[Int(random.next() % UInt64(fragments.count))]
            mirror.replace(NSRange(location: location, length: removeLength), with: insert)
            mirror.expectMatchesFullLex()
        }
    }

    @Test("toggling a task box flips its mark")
    func taskToggle() throws {
        let text = "- [ ] a\n- [x] b\n```\n- [ ] c\n```" as NSString
        let lexer = MarkdownLexer()
        lexer.reset(text: text)
        let open = try #require(lexer.taskToggle(at: 3, in: text))
        #expect(open.range == NSRange(location: 3, length: 1))
        #expect(open.replacement == "x")
        let done = try #require(lexer.taskToggle(at: 10, in: text))
        #expect(done.replacement == " ")
        #expect(lexer.taskToggle(at: 0, in: text) == nil)
        #expect(lexer.taskToggle(at: 6, in: text) == nil)
        #expect(lexer.taskToggle(at: 23, in: text) == nil)
    }

    @Test("lexing thousands of lines is fast")
    func performance() {
        let block = """
        ## Porada s [[Acme]] #acme
        - [ ] Připravit **návrh** a `kód`
        > citace s odkazem https://example.com
        | a | b |
        | --- | --- |
        | 1 | 2 |
        ```swift
        let x = 1 // #ne
        ```

        """
        let text = String(repeating: block, count: 500) as NSString
        let clock = ContinuousClock()
        let lexer = MarkdownLexer()
        let full = clock.measure { lexer.reset(text: text) }
        let mutable = NSMutableString(string: text)
        let edits = clock.measure {
            for index in 0..<200 {
                let location = 2500 * 10 + index
                mutable.replaceCharacters(in: NSRange(location: location, length: 0), with: "x")
                _ = lexer.update(text: mutable, editedRange: NSRange(location: location, length: 1), changeInLength: 1)
            }
        }
        #expect(lexer.lineCount == (text as String).components(separatedBy: "\n").count)
        // Generous bounds (debug build, shared CI machines); typical values are far lower.
        #expect(full < .seconds(2))
        #expect(edits / 200 < .milliseconds(5))
    }
}

/// Deterministic random numbers for reproducible fuzz tests.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
