import Foundation
import Testing
@testable import NotessCore

@Suite("Tag recognition")
struct TagTests {
    private func names(_ text: String) -> [String] {
        Tag.tags(in: text).map(\.name)
    }

    @Test("a hash followed by a word is a Tag")
    func simpleTag() {
        #expect(names("Kickoff #acme dnes") == ["acme"])
        #expect(names("#acme na začátku") == ["acme"])
        #expect(names("na konci #acme") == ["acme"])
    }

    @Test("Tags may contain letters with diacritics, digits, - and _")
    func allowedCharacters() {
        #expect(names("#Škola #přítel_č2 #q3-2026 #žluťoučký") == ["Škola", "přítel_č2", "q3-2026", "žluťoučký"])
    }

    @Test("decomposed diacritics stay part of the Tag")
    func decomposedDiacritics() {
        let decomposed = "#S\u{30C}kola"
        let tags = Tag.tags(in: decomposed)
        #expect(tags.count == 1)
        #expect(tags.first?.normalizedName == "škola")
    }

    @Test("a Tag ends at punctuation or whitespace")
    func tagEnd() {
        #expect(names("(#acme), #beta. #gamma! #delta?") == ["acme", "beta", "gamma", "delta"])
        #expect(names("#jedna/#dva") == ["jedna"])
    }

    @Test("Tags compare case-insensitively")
    func caseInsensitive() {
        let tags = Tag.tags(in: "#Acme #ACME #acme #Škola #ŠKOLA")
        #expect(Set(tags.map(\.normalizedName)) == ["acme", "škola"])
        #expect(Tag.normalize("#AcMe") == "acme")
    }

    @Test("Tags are not hierarchical: a slash ends the Tag")
    func notHierarchical() {
        #expect(names("#projekt/acme") == ["projekt"])
    }

    @Test("a heading is not a Tag, but a Tag inside a heading is")
    func headingsAreNotTags() {
        #expect(names("# Titulek") == [])
        #expect(names("## Porada") == [])
        #expect(names("###### H6") == [])
        #expect(names("## Porada #acme") == ["acme"])
        #expect(names("#Titulek") == ["Titulek"])
        #expect(names("# Titulek #acme") == ["acme"])
        #expect(names("### Hlouběji #acme ###") == ["acme"])
        #expect(names("###### H6 #acme") == ["acme"])
        #expect(names("Setext #acme\n---") == ["acme"])
        #expect(names("## `#kod` #acme") == ["acme"])
    }

    @Test("Tags inside inline code are ignored")
    func inlineCode() {
        #expect(names("`#ne` ale #ano") == ["ano"])
        #expect(names("``kód s ` a #ne`` #ano") == ["ano"])
    }

    @Test("Tags inside fenced code blocks are ignored")
    func fencedCode() {
        let text = """
        #pred
        ```swift
        let x = "#ne"
        #ne
        ```
        #po
        ~~~
        #ne
        ~~~
        """
        #expect(names(text) == ["pred", "po"])
    }

    @Test("an unclosed fence hides Tags until the end of the note")
    func unclosedFence() {
        #expect(names("#ano\n```\n#ne\n#ne") == ["ano"])
    }

    @Test("Tags inside indented code blocks are ignored")
    func indentedCode() {
        #expect(names("Text\n\n    #ne\n\n#ano") == ["ano"])
    }

    @Test("an indented line in a list is not code")
    func indentedListContinuation() {
        #expect(names("- položka\n\n    #ano") == ["ano"])
    }

    @Test("a hash inside a word, URL, entity or link target is not a Tag")
    func notTags() {
        #expect(names("C# a F#") == [])
        #expect(names("stránka#sekce") == [])
        #expect(names("&#123;") == [])
        #expect(names("https://example.com/#kotva") == [])
        #expect(names("[odkaz](https://example.com/#kotva)") == [])
        #expect(names("[[2026-10-14#Porada]]") == [])
        #expect(names("\\#escaped") == [])
    }

    @Test("a Tag may follow Czech quotes, dashes and a no-break space")
    func unicodeBoundaries() {
        #expect(names("„#acme“ v\u{00A0}#projekt —#pomlcka") == ["acme", "projekt", "pomlcka"])
        #expect(names("žluť#ne e\u{301}#ne") == [])
    }

    @Test("a Tag in a link's text counts, one in its target does not")
    func tagInLinkText() {
        #expect(names("[#acme kickoff](https://example.com/#ne)") == ["acme"])
    }

    @Test("a hash needs at least one letter")
    func needsLetter() {
        #expect(names("priorita #1 a #2026") == [])
        #expect(names("#2026-q3") == ["2026-q3"])
        #expect(names("# ") == [])
        #expect(names("#") == [])
    }

    @Test("Tags are found in lists, tasks, quotes, tables and emphasis")
    func tagsInContainers() {
        let text = """
        - #seznam
        - [ ] #ukol
        > #citace
        | A | B |
        | --- | --- |
        | #tabulka | x |
        *#kurziva* **#tucne**
        """
        #expect(names(text) == ["seznam", "ukol", "citace", "tabulka", "kurziva", "tucne"])
    }

    @Test("a Tag's range covers the hash and name in UTF-16 offsets")
    func ranges() {
        let tags = Tag.tags(in: "😀 #čau")
        #expect(tags.first?.range == NSRange(location: 3, length: 4))
    }

    @Test("Tags in front matter are ignored")
    func frontMatter() {
        #expect(names("---\ncreated: 2026-10-14\ntags: #ne\n---\n# Titulek\n#ano") == ["ano"])
    }
}

@Suite("Wiki-link recognition")
struct WikiLinkTests {
    @Test("a wiki-link names its target note")
    func target() {
        let links = WikiLink.links(in: "viz [[Jan Novák]] dnes")
        #expect(links == [WikiLink(target: "Jan Novák", section: nil, range: NSRange(location: 4, length: 13))])
    }

    @Test("a wiki-link may point at a Section")
    func section() {
        let link = WikiLink.links(in: "[[2026-10-14#Porada s Acme]]").first
        #expect(link?.target == "2026-10-14")
        #expect(link?.section == "Porada s Acme")
    }

    @Test("a wiki-link to a Section of the same note has an empty target")
    func sameNoteSection() {
        let link = WikiLink.links(in: "[[#Úvod]]").first
        #expect(link?.target == "")
        #expect(link?.section == "Úvod")
    }

    @Test("empty or unclosed brackets are not wiki-links")
    func invalid() {
        #expect(WikiLink.links(in: "[[]] [[  ]] [[nezavřeno").isEmpty)
        #expect(WikiLink.links(in: "[[a [b] c]]").isEmpty)
    }

    @Test("wiki-links inside code are ignored")
    func insideCode() {
        #expect(WikiLink.links(in: "`[[ne]]`\n```\n[[ne]]\n```\n[[ano]]").map(\.target) == ["ano"])
    }

    @Test("several wiki-links on one line")
    func several() {
        #expect(WikiLink.links(in: "[[A]] a [[B#C]]").map(\.target) == ["A", "B"])
    }
}

@Suite("Web-link recognition")
struct WebLinkTests {
    @Test("bare and Markdown HTTP links expose their clickable text")
    func linksAndRanges() {
        let text = "https://one.example and [Two](http://two.example/path \"title\")"
        let links = WebLink.links(in: text)

        #expect(links.map(\.url.absoluteString) == [
            "https://one.example",
            "http://two.example/path",
            "http://two.example/path"
        ])
        #expect(links.map { (text as NSString).substring(with: $0.range) } == [
            "https://one.example",
            "Two",
            "http://two.example/path"
        ])
    }

    @Test("code, scheme-less addresses and images are not web links")
    func exclusions() {
        let text = "`https://inline.example`\n```\nhttp://fenced.example\n```\nwww.example.com ![alt](https://image.example)"
        #expect(WebLink.links(in: text).isEmpty)
    }
}
