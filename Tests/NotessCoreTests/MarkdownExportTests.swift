import Foundation
import Testing
@testable import NotessCore

@Suite("Markdown export")
struct MarkdownExportTests {
    private func render(_ text: String, selecting selected: String) throws -> MarkdownExport.Output {
        let range = (text as NSString).range(of: selected)
        precondition(range.location != NSNotFound, "\(selected) not in the text")
        return try MarkdownExport.render(text, selection: range) { image in
            "embedded:\(image.source)"
        }
    }

    @Test("part of a link's text stays a link to its destination")
    func partialLinkText() throws {
        let output = try render("Viz [dokumentace projektu](https://example.com/docs) zde", selecting: "projektu")
        #expect(output.html.contains("<a href=\"https://example.com/docs\">projektu</a>"))
        #expect(output.plainText == "projektu")
    }

    @Test("a selected link destination alone is not visible content")
    func destinationOnly() throws {
        let output = try render("Viz [web](https://example.com/docs) zde", selecting: "example.com")
        #expect(output.isEmpty)
    }

    @Test("links to notes, files and other schemes are not clickable")
    func nonWebLinks() throws {
        let output = try render(
            "[soubor](obrazky/a.pdf) [app](notess://x) [js](javascript:alert(1))",
            selecting: "[soubor](obrazky/a.pdf) [app](notess://x) [js](javascript:alert(1))"
        )
        #expect(!output.html.contains("<a "))
        #expect(output.plainText == "soubor app js")
    }

    @Test("text that looks like HTML is escaped")
    func escaping() throws {
        let output = try render("Pozor na <script>alert(\"x\")</script> & spol.", selecting: "<script>alert(\"x\")</script> & spol")
        #expect(!output.html.contains("<script>"))
        #expect(output.html.contains("&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; spol"))
        #expect(output.plainText == "<script>alert(\"x\")</script> & spol")
    }

    @Test("part of one code line inside a fence is code")
    func partialFencedLine() throws {
        let output = try render("```\nlet hodnota = 42\n```", selecting: "hodnota")
        #expect(output.html.contains("<code"))
        #expect(output.html.contains(">hodnota</code>"))
        #expect(!output.html.contains("let"))
    }

    @Test("indented code loses only its block indentation")
    func indentedCode() throws {
        let output = try render("Text\n\n    if a {\n        b()\n    }", selecting: "    if a {\n        b()\n    }")
        #expect(output.plainText == "if a {\n    b()\n}")
        #expect(output.html.contains("<pre"))
    }

    @Test("selected nested items are indented relative to the shallowest one")
    func nestedListRelativeLevels() throws {
        let output = try render("- a\n  - b\n    - c\n  - d", selecting: "b\n    - c\n  - d")
        #expect(output.plainText == "• b\n    • c\n• d")
        #expect(!output.html.contains(">a<"))
    }

    @Test("a setext heading is a heading without its underline")
    func setextHeading() throws {
        let output = try render("Nadpis\n======\nText", selecting: "Nadpis\n======\nText")
        #expect(output.html.contains("<h1>Nadpis</h1>"))
        #expect(output.plainText == "Nadpis\nText")
    }

    @Test("a partly selected table keeps its columns and leaves unselected text out")
    func partialTable() throws {
        let output = try render("| A | B |\n| - | - |\n| a1 | b1 |\n| a2 | b2 |", selecting: "b1 |\n| a2")
        #expect(output.plainText == "\tb1\na2\t")
        #expect(output.html.contains("<td") && !output.html.contains("a1") && !output.html.contains("b2"))
    }

    @Test("a local image is handed to the embedder with its description")
    func localImageSeam() throws {
        var images: [MarkdownExport.LocalImage] = []
        let text = "Před ![Graf](obrazky/graf%20a.png) po"
        let output = try MarkdownExport.render(text, selection: NSRange(location: 0, length: (text as NSString).length)) { image in
            images.append(image)
            return "data:image/png;base64,AAAA"
        }
        #expect(images == [.init(source: "obrazky/graf%20a.png", description: "[Obrázek: Graf]")])
        #expect(output.html.contains("<img src=\"data:image/png;base64,AAAA\" alt=\"[Obrázek: Graf]\">"))
        #expect(output.plainText == "Před [Obrázek: Graf] po")
    }

    @Test("an embedding failure fails the whole export")
    func localImageFailure() {
        struct Failure: Error {}
        #expect(throws: Failure.self) {
            try MarkdownExport.render("![x](a.png)", selection: NSRange(location: 0, length: 11)) { _ in throw Failure() }
        }
    }

    @Test("Windows line breaks are not copied")
    func crlf() throws {
        let output = try render("# A\r\nb **c**\r\n", selecting: "# A\r\nb **c**")
        #expect(output.plainText == "A\nb c")
        #expect(!output.html.contains("\r"))
    }
}
