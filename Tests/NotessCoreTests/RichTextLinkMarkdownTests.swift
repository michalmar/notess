import Testing
@testable import NotessCore

@Suite("Rich text links to Markdown")
struct RichTextLinkMarkdownTests {
    typealias Segment = RichTextLinkMarkdown.Segment

    @Test func namedLinkBecomesMarkdownLink() {
        let segments: [Segment] = [.text("See "), .link(label: "the docs", destination: "https://example.com/docs"), .text(".")]
        #expect(RichTextLinkMarkdown.markdown(from: segments) == "See [the docs](https://example.com/docs).")
    }

    @Test func noLinksYieldsNil() {
        #expect(RichTextLinkMarkdown.markdown(from: [.text("plain")]) == nil)
        #expect(RichTextLinkMarkdown.markdown(from: []) == nil)
    }

    @Test(arguments: [
        "javascript:alert(1)", "file:///etc/hosts", "notess://note", "/relative", "#top",
        "https://", "https:///path", "https://exa mple.com", "mailto:", "mailto:a b@e.com", "  ",
    ])
    func unusableDestinationKeepsOnlyTheText(destination: String) {
        #expect(RichTextLinkMarkdown.markdown(from: [.link(label: "x", destination: destination)]) == nil)
        #expect(RichTextLinkMarkdown.markdown(from: [.link(label: "x", destination: destination), .link(label: "y", destination: "https://e.com")])
            == "x[y](https://e.com)")
    }

    @Test func webLinkShownAsItsOwnURLStaysText() {
        #expect(RichTextLinkMarkdown.markdown(from: [.link(label: "https://e.com/a", destination: "https://e.com/a")]) == nil)
        #expect(RichTextLinkMarkdown.markdown(from: [.link(label: "a@e.com", destination: "mailto:a@e.com")]) == "[a@e.com](mailto:a@e.com)")
        #expect(RichTextLinkMarkdown.markdown(from: [.link(label: "mailto:a@e.com", destination: "mailto:a@e.com")]) == "[mailto:a@e.com](mailto:a@e.com)")
    }

    @Test func labelMarkdownIsEscaped() {
        let segments: [Segment] = [.link(label: #"*a* _b_ [c] `d` <e> ~f~ \g &amp; & h"#, destination: "https://e.com")]
        #expect(RichTextLinkMarkdown.markdown(from: segments) == #"[\*a\* \_b\_ \[c\] \`d\` \<e\> \~f\~ \\g \&amp; & h](https://e.com)"#)
    }

    @Test(arguments: [
        ("Wow!", #"Wow\![x](https://e.com)"#),
        (#"Wow\!"#, #"Wow\![x](https://e.com)"#),
        (#"C:\Temp\"#, #"C:\Temp\\[x](https://e.com)"#),
        (#"C:\\"#, #"C:\\[x](https://e.com)"#),
    ])
    func textBeforeLinkKeepsItALink(before: String, expected: String) {
        #expect(RichTextLinkMarkdown.markdown(from: [.text(before), .link(label: "x", destination: "https://e.com")]) == expected)
    }

    @Test func destinationIsKeptButMadeSafeInsideParentheses() {
        func markdown(_ destination: String) -> String? {
            RichTextLinkMarkdown.markdown(from: [.link(label: "x", destination: destination)])
        }
        #expect(markdown(" https://e.com/a b ") == "[x](https://e.com/a%20b)")
        #expect(markdown("https://e.com/w/A_(b)") == "[x](https://e.com/w/A_(b))")
        #expect(markdown("https://e.com/a)") == "[x](https://e.com/a%29)")
        #expect(markdown("https://e.com/<a>`\\") == "[x](https://e.com/%3Ca%3E%60%5C)")
        #expect(markdown("https://e.com/long\r\n/path?a=1\t&b=2") == "[x](https://e.com/long/path?a=1&b=2)")
        #expect(markdown("https://e.com/a\u{7}") == nil)
    }

    @Test func labelWhitespaceCollapsesInsideAndStaysOutsideTheLink() {
        let segments: [Segment] = [.text("A"), .link(label: "\n  two\n words ", destination: "https://e.com"), .text("B")]
        #expect(RichTextLinkMarkdown.markdown(from: segments) == "A\n  [two words](https://e.com) B")
        #expect(RichTextLinkMarkdown.markdown(from: [.link(label: " \n ", destination: "https://e.com")]) == nil)
    }

    @Test func visibleTextDropsDestinations() {
        let segments: [Segment] = [.text("See "), .link(label: "the\n docs", destination: "https://e.com"), .text(".")]
        #expect(RichTextLinkMarkdown.visibleText(from: segments) == "See the docs.")
        #expect(RichTextLinkMarkdown.visibleText(from: [.link(label: "a\n", destination: "x")]) == "a\n")
    }
}
