import Foundation
import Testing
@testable import NotessCore

/// Texts of all tokens of `kind` in `text`.
func spans(_ text: String, _ kind: MarkdownToken.Kind) -> [String] {
    let string = text as NSString
    return MarkdownSyntax.tokens(in: text).filter { $0.kind == kind }.map { string.substring(with: $0.range) }
}

@Suite("Markdown syntax")
struct MarkdownSyntaxTests {
    @Test("ATX headings cover the line, hashes are muted markers")
    func atxHeadings() {
        #expect(spans("# Titulek", .heading(level: 1)) == ["# Titulek"])
        #expect(spans("### Třetí ###", .heading(level: 3)) == ["### Třetí ###"])
        #expect(spans("### Třetí ###", .syntaxMarker) == ["###", "###"])
        #expect(spans("####### sedm", .heading(level: 7)).isEmpty)
        #expect(MarkdownSyntax.tokens(in: "#bez mezery").allSatisfy { $0.kind == .tag })
    }

    @Test("setext headings use the next line as their underline")
    func setextHeadings() {
        #expect(spans("Titulek\n===", .heading(level: 1)) == ["Titulek"])
        #expect(spans("Titulek\n---", .heading(level: 2)) == ["Titulek"])
        #expect(spans("Titulek\n---", .syntaxMarker) == ["---"])
        #expect(spans("- položka\n---", .heading(level: 2)).isEmpty)
    }

    @Test("bold, italic and strikethrough with muted markers")
    func emphasis() {
        let text = "**tučně** *kurzíva* _také_ __tučně__ ~~škrt~~ ***obojí***"
        #expect(spans(text, .strong) == ["tučně", "tučně", "obojí"])
        #expect(spans(text, .emphasis) == ["kurzíva", "také", "**obojí**"])
        #expect(spans(text, .strikethrough) == ["škrt"])
        #expect(spans(text, .syntaxMarker) == ["**", "**", "*", "*", "_", "_", "__", "__", "~~", "~~", "**", "**", "*", "*"])
    }

    @Test("intraword underscores and lone stars are not emphasis")
    func notEmphasis() {
        #expect(spans("snake_case_name", .emphasis).isEmpty)
        #expect(spans("2 * 3 * 4", .emphasis).isEmpty)
        #expect(spans("**neuzavřeno", .strong).isEmpty)
    }

    @Test("inline code hides other syntax")
    func inlineCode() {
        #expect(spans("a `**x** [[y]]` b", .inlineCode) == ["**x** [[y]]"])
        #expect(spans("a `**x** [[y]]` b", .strong).isEmpty)
        #expect(spans("a `**x** [[y]]` b", .wikiLink).isEmpty)
        #expect(spans("neuzavřený `kód", .inlineCode).isEmpty)
    }

    @Test("fenced and indented code blocks")
    func codeBlocks() {
        let text = "```swift\nlet a = 1\n**b**\n```\ntext"
        #expect(spans(text, .codeBlock) == ["let a = 1", "**b**"])
        #expect(spans(text, .syntaxMarker) == ["```swift", "```"])
        #expect(spans(text, .strong).isEmpty)
        #expect(spans("p\n\n    kód\n", .codeBlock) == ["    kód"])
        #expect(spans("odstavec\n    pokračování", .codeBlock).isEmpty)
    }

    @Test("a longer fence is not closed by a shorter one")
    func fenceLength() {
        #expect(spans("````\n```\nx\n````\ny", .codeBlock) == ["```", "x"])
    }

    @Test("lists and ordered lists")
    func lists() {
        let text = "- a\n* b\n+ c\n1. d\n2) e\n  - f\n-bez mezery"
        #expect(spans(text, .listMarker) == ["-", "*", "+", "1.", "2)", "-"])
    }

    @Test("task items are recognised with their state")
    func tasks() {
        let text = "- [ ] udělat\n- [x] hotovo\n* [X] také\n- [] ne\n- [ ]bez mezery"
        #expect(spans(text, .task(isChecked: false)) == ["[ ]"])
        #expect(spans(text, .task(isChecked: true)) == ["[x]", "[X]"])
        #expect(spans(text, .completedTask) == ["hotovo", "také"])
    }

    @Test("blockquotes")
    func blockquotes() {
        #expect(spans("> citace\n>> vnořená", .blockquote) == ["> citace", ">> vnořená"])
        #expect(spans("> - [ ] úkol", .task(isChecked: false)) == ["[ ]"])
    }

    @Test("GFM tables: header, delimiter row and body")
    func tables() {
        let text = "| Jméno | Role |\n| :--- | ---: |\n| Jan | PM |\nkonec\n\n|a|\n|-|-|"
        #expect(spans(text, .tableHeader) == ["| Jméno | Role |"])
        let markers = spans(text, .syntaxMarker)
        #expect(markers.filter { $0 == "|" }.count == 6)
        #expect(markers.contains("| :--- | ---: |"))
        // Column counts must match.
        #expect(spans("|a|\n|-|-|", .tableHeader).isEmpty)
        #expect(spans("a | b\n--|--\nc | d", .tableHeader) == ["a | b"])
    }

    @Test("links, images, autolinks and bare URLs")
    func links() {
        let text = "[Notess](https://x.cz \"t\") ![obr](a.png) <https://a.cz> viz https://b.cz/x_(y). a www.c.cz"
        #expect(spans(text, .link) == ["Notess", "obr", "https://a.cz", "https://b.cz/x_(y)", "www.c.cz"])
        #expect(spans(text, .linkDestination) == ["https://x.cz \"t\"", "a.png"])
        #expect(spans(text, .image(source: "a.png")) == ["![obr](a.png)"])
        #expect(spans("![](attachments/a.png \"title\")", .image(source: "attachments/a.png")) == ["![](attachments/a.png \"title\")"])
        #expect(spans("[jen text] a [x]", .link).isEmpty)
    }

    @Test("wiki-links and Tags are highlighted with muted brackets")
    func wikiLinksAndTags() {
        let text = "[[Jan#Kontakt]] #acme"
        #expect(spans(text, .wikiLink) == ["[[Jan#Kontakt]]"])
        #expect(spans(text, .tag) == ["#acme"])
        #expect(spans(text, .syntaxMarker) == ["[[", "]]"])
    }

    @Test("thematic breaks and front matter")
    func breaksAndFrontMatter() {
        #expect(spans("a\n\n***\n\n- - -", .thematicBreak) == ["***", "- - -"])
        #expect(spans("---\ncreated: 2026-10-14\n---\n# T", .frontMatter) == ["---", "created: 2026-10-14", "---"])
        #expect(spans("---\ncreated: 2026-10-14\n---\n# T", .heading(level: 1)) == ["# T"])
    }

    @Test("backslash escapes are literal")
    func escapes() {
        #expect(spans("\\*ne\\*", .emphasis).isEmpty)
        #expect(spans("\\[[ne]]", .wikiLink).isEmpty)
    }

    @Test("CRLF line endings are handled")
    func crlf() {
        #expect(spans("# A\r\n**b**\r\n", .strong) == ["b"])
        #expect(spans("# A\r\n**b**\r\n", .heading(level: 1)) == ["# A"])
    }
}
