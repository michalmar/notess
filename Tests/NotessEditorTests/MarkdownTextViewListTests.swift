import AppKit
import Testing
@testable import NotessEditor

/// Markdown lists in the editor (issue #106): solid bullets and source numbers
/// with a hanging indent, and Enter continuing or ending a list, while the
/// Markdown text stays as it is.
@MainActor
@Suite("Markdown lists in the editor")
struct MarkdownTextViewListTests {
    // MARK: Enter

    @Test("Enter at the end of a nonempty item starts the next item: one notification, one undo step", arguments: [
        ("- text‸", "- text\n- ‸"),
        ("* text‸", "* text\n* ‸"),
        ("+ text‸", "+ text\n+ ‸"),
        ("1. text‸", "1. text\n2. ‸"),
        ("9. text‸", "9. text\n10. ‸"),
        ("2) text‸", "2) text\n3) ‸"),
        ("099. text‸", "099. text\n100. ‸"),
        ("999999998. text‸", "999999998. text\n999999999. ‸"),
        ("-   široká mezera‸", "-   široká mezera\n-   ‸"),
        ("-\ttabulátor‸", "-\ttabulátor\n-\t‸"),
        ("- [ ] úkol‸", "- [ ] úkol\n- ‸"),
        ("- [x] hotovo‸", "- [x] hotovo\n- ‸"),
        ("- a\n  - b‸", "- a\n  - b\n  - ‸"),
        ("1. a\n    - b‸", "1. a\n    - b\n    - ‸"),
        ("- a\n\t- b‸", "- a\n\t- b\n\t- ‸"),
        ("1. a\n   - b\n     1) c‸", "1. a\n   - b\n     1) c\n     2) ‸"),
        ("- a\n  - b\n- c‸", "- a\n  - b\n- c\n- ‸"),
        ("- a\n\n  odstavec\n- b‸", "- a\n\n  odstavec\n- b\n- ‸"),
        ("- žluťoučký kůň 🐎‸", "- žluťoučký kůň 🐎\n- ‸"),
        ("- a‸\n- b", "- a\n- ‸\n- b"),
        ("1. a‸\n2. b", "1. a\n2. ‸\n2. b"),
        ("- a\r\n- b‸", "- a\r\n- b\r\n- ‸"),
        ("- a‸\r\n- b", "- a\r\n- ‸\r\n- b"),
    ])
    func continues(before: String, after: String) throws {
        let editor = try Editor(before)

        let changes = editor.changes { editor.enter() }

        #expect(editor.marked == after)
        #expect(changes == 1)
        #expect(editor.undoManager.undoActionName == "Pokračovat v seznamu")
        editor.undoManager.undo()
        #expect(editor.textView.string == plain(before))
        editor.undoManager.redo()
        #expect(editor.textView.string == plain(after))
        #expect(editor.undoManager.canRedo == false)
    }

    @Test("Enter on an empty or blank item leaves a plain empty line, nested too", arguments: [
        ("- ‸", "‸"),
        ("- a\n- ‸", "- a\n‸"),
        ("- a\n-   ‸", "- a\n‸"),
        ("- a\n  - ‸", "- a\n‸"),
        ("- a\n\t- ‸", "- a\n‸"),
        ("1. a\n   1) ‸", "1. a\n‸"),
        ("1. a\n2. ‸\n3. b", "1. a\n‸\n3. b"),
        ("- a\r\n- ‸\r\n\r\nb", "- a\r\n‸\r\n\r\nb"),
    ])
    func ends(before: String, after: String) throws {
        let editor = try Editor(before)

        let changes = editor.changes { editor.enter() }

        #expect(editor.marked == after)
        #expect(changes == 1)
        #expect(editor.undoManager.undoActionName == "Ukončit seznam")
        editor.undoManager.undo()
        #expect(editor.textView.string == plain(before))
        editor.undoManager.redo()
        #expect(editor.textView.string == plain(after))
    }

    @Test("a second Enter on the new empty item ends the list; undo steps back one Enter at a time", arguments: [
        ("- text‸", "- text\n- ‸", "- text\n‸"),
        ("9. text‸", "9. text\n10. ‸", "9. text\n‸"),
        ("- a\n  - b‸", "- a\n  - b\n  - ‸", "- a\n  - b\n‸"),
    ])
    func continueThenEnd(start: String, continued: String, ended: String) throws {
        let editor = try Editor(start)

        editor.enter()
        #expect(editor.marked == continued)
        let changes = editor.changes { editor.enter() }
        #expect(editor.marked == ended)
        #expect(changes == 1)

        editor.event { editor.textView.insertText("dál", replacementRange: editor.textView.selectedRange()) }
        #expect(editor.marked == plain(ended) + "dál‸")
        editor.undoManager.undo()
        editor.undoManager.undo()
        #expect(editor.textView.string == plain(continued))
        editor.undoManager.undo()
        #expect(editor.textView.string == plain(start))
    }

    @Test("Enter anywhere else breaks the line as usual", arguments: [
        ("- te‸xt", "- te\n‸xt"),
        ("- a\n  pokračování‸", "- a\n  pokračování\n‸"),
        ("- a\nlíné pokračování‸", "- a\nlíné pokračování\n‸"),
        ("- a\n\n  odstavec položky‸", "- a\n\n  odstavec položky\n‸"),
        ("obyčejný odstavec‸", "obyčejný odstavec\n‸"),
        ("```\n- kód‸\n```", "```\n- kód\n‸\n```"),
        ("odstavec\n\n    - odsazený kód‸", "odstavec\n\n    - odsazený kód\n‸"),
        ("---\n- a‸\n---\ntext", "---\n- a\n‸\n---\ntext"),
        ("- - -‸", "- - -\n‸"),
        ("* * *‸", "* * *\n‸"),
        ("# - nadpis‸", "# - nadpis\n‸"),
        ("> - citace‸", "> - citace\n‸"),
        ("-text‸", "-text\n‸"),
        ("999999999. a‸", "999999999. a\n‸"),
        ("1234567890. a‸", "1234567890. a\n‸"),
    ])
    func ordinaryNewline(before: String, after: String) throws {
        let editor = try Editor(before)

        let changes = editor.changes { editor.enter() }

        #expect(editor.marked == after)
        #expect(changes == 1)
        #expect(!["Pokračovat v seznamu", "Ukončit seznam"].contains(editor.undoManager.undoActionName))
    }

    @Test("with a selection, Enter replaces it as usual")
    func selection() throws {
        let editor = try Editor("- text")
        editor.textView.setSelectedRange(NSRange(location: 2, length: 4))

        editor.enter()

        #expect(editor.marked == "- \n‸")
    }

    @Test("Option+Enter is a plain line break")
    func optionEnter() throws {
        let editor = try Editor("- text‸")

        editor.event { editor.textView.insertNewlineIgnoringFieldEditor(nil) }

        #expect(editor.marked == "- text\n‸")
    }

    @Test("Enter during text composition does not continue the list")
    func composition() throws {
        let editor = try Editor("- text‸")
        editor.event {
            editor.textView.setMarkedText("š", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        #expect(editor.textView.hasMarkedText())

        editor.enter()

        #expect(!editor.textView.string.contains("\n- "))
        #expect(!["Pokračovat v seznamu", "Ukončit seznam"].contains(editor.undoManager.undoActionName))
    }

    @Test("the read-only view ignores Enter")
    func readOnlyEnter() {
        let (_, textView) = readOnlyView("- text\n- ")
        for location in [6, 9] {
            textView.setSelectedRange(NSRange(location: location, length: 0))
            textView.insertNewline(nil)
            #expect(textView.string == "- text\n- ")
        }
    }

    @Test("Enter in a table after a list still adds a row; Tab in an item is a tab character")
    func tablesAndTab() throws {
        let editor = try Editor("- a\n\n| a | b |\n| - | - |\n| c | d‸ |")
        editor.enter()
        #expect(editor.marked == "- a\n\n| a | b |\n| - | - |\n| c | d |\n| ‸ |  |")
        #expect(editor.undoManager.undoActionName == "Přidat řádek")

        editor.load("- a‸")
        editor.event { editor.textView.insertTab(nil) }
        #expect(editor.marked == "- a\t‸")
    }

    // MARK: Layout

    private static let long = "text, který je v úzkém editoru dost dlouhý na to, aby se zalomil do více řádků"

    private static let nested = """
        - první \(long)
          - druhá \(long)
            1. třetí \(long)

               čtvrtá \(long)
        - pátá \(long)
        """

    @Test("wrapped lines and continuation paragraphs line up with the item text, one step further per level")
    func hangingIndent() throws {
        let editor = try Editor(Self.nested, width: 340)
        expectNestedLayout(in: editor.textView)
        #expect(editor.textView.string == Self.nested)
    }

    @Test("the read-only view lays lists out the same way")
    func readOnlyLayout() throws {
        let (_, textView) = readOnlyView(Self.nested, width: 340)
        expectNestedLayout(in: textView)
        let rendering = try Rendering(textView)
        expectBullet(rendering.markerInk(of: "první", in: textView))
        expectNumber(rendering.markerInk(of: "třetí", in: textView), before: "třetí", in: textView)
    }

    private func expectNestedLayout(in textView: NSTextView, sourceLocation: SourceLocation = #_sourceLocation) {
        let first = expectHangingIndent(of: "první", in: textView, sourceLocation: sourceLocation)
        let second = expectHangingIndent(of: "druhá", in: textView, sourceLocation: sourceLocation)
        let third = expectHangingIndent(of: "třetí", in: textView, sourceLocation: sourceLocation)
        let continuation = expectHangingIndent(of: "čtvrtá", in: textView, sourceLocation: sourceLocation)
        let back = expectHangingIndent(of: "pátá", in: textView, sourceLocation: sourceLocation)
        #expect(second - first > 10, sourceLocation: sourceLocation)
        #expect(abs((third - second) - (second - first)) < 1, sourceLocation: sourceLocation)
        #expect(abs(continuation - third) < 1, sourceLocation: sourceLocation)
        #expect(abs(back - first) < 1, sourceLocation: sourceLocation)
    }

    @Test("two spaces, four spaces and a tab each nest one level; less indentation returns to the parent", arguments: ["  ", "    ", "\t"])
    func nestingIndentation(indent: String) throws {
        let editor = try Editor("- a\n\(indent)- b\n\(indent)\(indent)- c\n\(indent)- d\n- e")
        let x = ["a", "b", "c", "d", "e"].map { editor.x(ofItem: $0) }
        let step = x[1] - x[0]
        #expect(step > 10)
        #expect(abs(x[2] - x[1] - step) < 1)
        #expect(abs(x[3] - x[1]) < 1)
        #expect(abs(x[4] - x[0]) < 1)

        let reference = try Editor("- a\n  - b\n    - c")
        #expect(abs(x[0] - reference.x(ofItem: "a")) < 1)
        #expect(abs(x[1] - reference.x(ofItem: "b")) < 1)
        #expect(abs(x[2] - reference.x(ofItem: "c")) < 1)
    }

    @Test("ordered and unordered items nest in each other")
    func mixedNesting() throws {
        let editor = try Editor("1. a\n   - b\n     1) c\n   - d\n2. e")
        let x = ["a", "b", "c", "d", "e"].map { editor.x(ofItem: $0) }
        let step = x[1] - x[0]
        #expect(step > 10)
        #expect(abs(x[2] - x[1] - step) < 1)
        #expect(abs(x[3] - x[1]) < 1)
        #expect(abs(x[4] - x[0]) < 1)
        let rendering = try Rendering(editor.textView)
        expectBullet(rendering.markerInk(of: "b", in: editor.textView))
        expectNumber(rendering.markerInk(of: "c", in: editor.textView), before: "c", in: editor.textView)
    }

    @Test("CRLF line breaks, Czech and emoji lay out like LF")
    func crlfAndUnicode() throws {
        let lf = "- 🐎 žluťoučký kůň \(Self.long)\n  - ď\n- ó"
        let editor = try Editor(lf, width: 340)
        let crlf = try Editor(lf.replacingOccurrences(of: "\n", with: "\r\n"), width: 340)
        for item in ["🐎", "ď", "ó"] {
            #expect(abs(editor.x(ofItem: item) - crlf.x(ofItem: item)) < 0.5)
        }
        expectHangingIndent(of: "🐎", in: editor.textView)
        expectHangingIndent(of: "🐎", in: crlf.textView)
        #expect(crlf.textView.string == lf.replacingOccurrences(of: "\n", with: "\r\n"))
    }

    @Test("numbers keep their source value; the text of numbers up to 999 lines up and longer ones never overlap it")
    func numbering() throws {
        let editor = try Editor("1. a\n9. b\n10. c\n100. d\n999. e\n1000. f\n123456789. g\n\n2) h\n10) i")
        let textView = editor.textView
        let rendering = try Rendering(textView)
        let aligned = ["a", "b", "c", "d", "e", "h", "i"]
        let x = editor.x(ofItem: "a")
        var rightEdges: [CGFloat] = []
        var widths: [CGFloat] = []
        for item in aligned {
            #expect(abs(editor.x(ofItem: item) - x) < 1, "\(item)")
            let ink = rendering.markerInk(of: item, in: textView)
            expectNumber(ink, before: item, in: textView)
            rightEdges.append(ink?.maxX ?? .nan)
            widths.append(ink?.width ?? .nan)
        }
        for edge in rightEdges.dropFirst() { #expect(abs(edge - rightEdges[0]) < 1) }
        #expect(widths[1] < widths[2] && widths[2] < widths[3])
        for item in ["f", "g"] {
            #expect(editor.x(ofItem: item) >= x - 0.5)
            expectNumber(rendering.markerInk(of: item, in: textView), before: item, in: textView)
        }
        #expect(textView.string == "1. a\n9. b\n10. c\n100. d\n999. e\n1000. f\n123456789. g\n\n2) h\n10) i")
    }

    @Test("every unordered item gets the same solid round bullet in place of its marker, at every level")
    func bullets() throws {
        let editor = try Editor("- a\n* a\n+ a\n  - a\n    * a\n- a [ ]")
        let textView = editor.textView
        let rendering = try Rendering(textView)
        let string = textView.string as NSString
        var bullets: [NSRect] = []
        var location = 0
        while true {
            let found = string.range(of: "a", range: NSRange(location: location, length: string.length - location))
            guard found.location != NSNotFound else { break }
            let ink = rendering.markerInk(at: found.location, in: textView)
            expectBullet(ink)
            bullets.append(ink ?? .zero)
            location = found.upperBound
        }
        #expect(bullets.count == 6)
        // The same bullet whatever the marker: no source marker shows through.
        for bullet in bullets[1...2] {
            #expect(abs(bullet.minX - bullets[0].minX) < 0.5 && abs(bullet.maxX - bullets[0].maxX) < 0.5)
        }
        for bullet in bullets.dropFirst() {
            #expect(abs(bullet.width - bullets[0].width) < 0.5 && abs(bullet.height - bullets[0].height) < 0.5)
        }
        #expect(bullets[3].minX > bullets[0].maxX && bullets[4].minX > bullets[3].maxX)
    }

    @Test("resizing and zooming realign lists without editing the note")
    func resizeAndZoom() throws {
        let editor = try Editor(Self.nested, width: 400)
        editor.textView.setSelectedRange(NSRange(location: 5, length: 3))
        let normal = editor.x(ofItem: "první")

        let changes = editor.changes {
            editor.resize(width: 300)
            expectNestedLayout(in: editor.textView)
            editor.zoom(fontSize: 22.5)
            expectNestedLayout(in: editor.textView)
            #expect(editor.x(ofItem: "první") - editor.textView.textContainerOrigin.x > (normal - editor.textView.textContainerOrigin.x) * 1.3)
            if let rendering = try? Rendering(editor.textView) {
                expectBullet(rendering.markerInk(of: "první", in: editor.textView), fontSize: 22.5)
            }
            editor.resize(width: 600)
            editor.zoom(fontSize: 15)
            expectNestedLayout(in: editor.textView)
        }

        #expect(changes == 0)
        #expect(editor.undoManager.canUndo == false)
        #expect(editor.textView.string == Self.nested)
        #expect(editor.textView.selectedRange() == NSRange(location: 5, length: 3))
        #expect(abs(editor.x(ofItem: "první") - normal) < 0.5)
    }

    // MARK: Editing

    @Test("after edits the editor looks exactly like a fresh editor with the same text")
    func incrementalMatchesFresh() throws {
        let editor = try Editor("- jedna\n- dva\n- tři\n\nodstavec\nkonec")
        func edit(_ replacing: String, with replacement: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
            let range = (editor.textView.string as NSString).range(of: replacing)
            try #require(range.location != NSNotFound, sourceLocation: sourceLocation)
            editor.event {
                editor.textView.setSelectedRange(range)
                editor.textView.insertText(replacement, replacementRange: range)
            }
            try expectLooksFresh(editor, sourceLocation: sourceLocation)
        }

        try edit("- dva", with: "  - dva")
        try edit("- tři", with: "9. tři")
        try edit("9. tři", with: "10. tři")
        try edit("odstavec", with: "    odstavec")
        try edit("- jedna", with: "jedna")
        try edit("konec", with: "* konec")
        try edit("* konec", with: "*konec")
        try edit("jedna", with: "```\njedna")
        try edit("```\n", with: "")
        try edit("  - dva", with: "\t- dva")
        try edit("\t- dva", with: "- dva")

        editor.load("- a\n‸")
        for character in "- b" {
            editor.event { editor.textView.insertText(String(character), replacementRange: editor.textView.selectedRange()) }
            try expectLooksFresh(editor)
        }
        editor.enter()
        try expectLooksFresh(editor)
        editor.enter()
        try expectLooksFresh(editor)
        editor.undoManager.undo()
        try expectLooksFresh(editor)
    }

    private func expectLooksFresh(_ editor: Editor, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let fresh = try Editor(editor.textView.string)
        fresh.textView.setSelectedRange(editor.textView.selectedRange())
        let edited = try Rendering(editor.textView)
        let expected = try Rendering(fresh.textView)
        #expect(edited.matches(expected), "\(editor.textView.string.debugDescription)", sourceLocation: sourceLocation)
    }

    @Test("the source stays Markdown: the marker can be selected, copied and deleted")
    func sourcePreserved() throws {
        let source = "- jedna\n  * dva\n10. tři\n\n  pokračování"
        let editor = try Editor(source)
        let pasteboard = NSPasteboard(name: .init("NotessListTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        func copy(_ range: NSRange) -> String? {
            editor.textView.setSelectedRange(range)
            pasteboard.clearContents()
            #expect(editor.textView.writeSelection(to: pasteboard, types: editor.textView.writablePasteboardTypes))
            return pasteboard.string(forType: .string)
        }

        #expect(copy(NSRange(location: 0, length: (source as NSString).length)) == source)
        #expect(copy(NSRange(location: 0, length: 1)) == "-")
        #expect(copy(NSRange(location: 5, length: 9)) == "na\n  * dv")

        editor.textView.setSelectedRange(NSRange(location: 1, length: 0))
        editor.event { editor.textView.deleteBackward(nil) }
        #expect(editor.marked == "‸ jedna\n  * dva\n10. tři\n\n  pokračování")
        #expect(!editor.textView.string.contains("•"))
    }

    // MARK: Other Markdown

    private static let mixed = """
        ---
        title: Test
        ---
        # Nadpis
        Text s *důrazem*, `kódem`, [odkazem](https://example.com), [[Wiki]] a #tag.

        - položka s *důrazem*, `kódem`, [odkazem](https://example.com), [[Wiki]] a #tag
        - [ ] úkol
        - [x] hotový úkol
          1. vnořená ![](attachments/image.png)

        Odstavec po seznamu.

        > - citace se seznamem

        | a | b |
        | - | - |
        | - c | d |

        ```
        - v kódu
        ```

            - odsazený kód

        ## Druhý nadpis
        - poslední
        """

    @Test("lists leave other Markdown alone and keep its inline formatting")
    func otherMarkdown() throws {
        let editor = try Editor(Self.mixed)
        let textView = editor.textView
        let string = textView.string as NSString
        let plainX = editor.x(of: "Text s")

        for line in ["title:", "# Nadpis", "Odstavec po", "> - citace", "```", "- v kódu", "    - odsazený", "## Druhý"] {
            #expect(abs(editor.x(of: line) - plainX) < 0.5, "\(line)")
        }
        for line in ["- v kódu", "> - citace", "| - c"] {
            let dash = string.range(of: line).location + (line.hasPrefix("-") ? 0 : 2)
            let color = textView.textStorage?.attribute(.foregroundColor, at: dash, effectiveRange: nil) as? NSColor
            #expect(color != nil && color?.alphaComponent != 0, "\(line)")
        }
        let item = editor.x(ofItem: "položka")
        #expect(item > plainX + 5)
        #expect(abs(editor.x(of: "[ ] úkol") - item) < 1)
        #expect(abs(editor.x(of: "[x] hotový") - item) < 1)
        #expect(editor.x(of: "vnořená") > item + 10)
        #expect(abs(editor.x(ofItem: "poslední") - item) < 1)

        // Inline formatting inside an item is the same as in a paragraph.
        let paragraph = string.range(of: "Text s").location
        let listItem = string.range(of: "položka").location
        for word in ["důrazem", "kódem", "odkazem", "Wiki", "#tag"] {
            let inParagraph = string.range(of: word, range: NSRange(location: paragraph, length: listItem - paragraph)).location
            let inItem = string.range(of: word, range: NSRange(location: listItem, length: string.length - listItem)).location
            for key: NSAttributedString.Key in [.font, .foregroundColor, .backgroundColor, .underlineStyle, .link] {
                let a = textView.textStorage?.attribute(key, at: inParagraph, effectiveRange: nil) as? NSObject
                let b = textView.textStorage?.attribute(key, at: inItem, effectiveRange: nil) as? NSObject
                #expect(a == b, "\(word) \(key.rawValue)")
            }
        }
        let heading = textView.textStorage?.attribute(.font, at: string.range(of: "Nadpis").location, effectiveRange: nil) as? NSFont
        let body = textView.textStorage?.attribute(.font, at: paragraph, effectiveRange: nil) as? NSFont
        #expect((heading?.pointSize ?? 0) > (body?.pointSize ?? 0))

        // Tasks: checked text is struck through and a box still toggles.
        let done = textView.textStorage?.attribute(.strikethroughStyle, at: string.range(of: "hotový").location, effectiveRange: nil) as? Int
        #expect(done == NSUnderlineStyle.single.rawValue)
        var toggled = false
        editor.event { toggled = textView.toggleTask(at: string.range(of: "[ ] úkol").location + 1) }
        #expect(toggled)
        #expect(textView.string.contains("- [x] úkol"))
        let struck = textView.textStorage?.attribute(.strikethroughStyle, at: (textView.string as NSString).range(of: "x] úkol").location + 3, effectiveRange: nil) as? Int
        #expect(struck == NSUnderlineStyle.single.rawValue)
        #expect(abs(editor.x(of: "[x] úkol") - item) < 1)

        // A table after the list is still a table.
        #expect(abs(editor.x(of: "| a |") - editor.x(of: "| - c")) < 0.5)
        let rendering = try Rendering(textView)
        #expect(rendering.markerInk(of: "v kódu", in: textView) != nil)
    }

    @Test("an inline image in a list item keeps the item's indent")
    func inlineImage() throws {
        let editor = try Editor("- a\n  1. vnořená ![](attachments/image.png)\n\nOdstavec", width: 500)
        let before = editor.x(ofItem: "vnořená")
        let below = editor.x(of: "Odstavec")
        let png = try #require(Self.png())
        editor.textView.noteURL = URL(filePath: "/Vault/Notes/Idea.md")
        editor.textView.inlineImageData = { _ in png }

        let changes = editor.changes {
            editor.textView.refreshInlineImages()
            editor.layout()
        }

        #expect(editor.textView.displayedInlineImageCount == 1)
        #expect(abs(editor.x(ofItem: "vnořená") - before) < 0.5)
        #expect(abs(editor.x(of: "Odstavec") - below) < 0.5)
        let image = try #require(editor.textView.visibleInlineImageFrames.first?.frame)
        let item = try #require(editor.lines(of: "vnořená").last)
        #expect(image.minY >= item.frame.maxY - 0.5)
        #expect(editor.lines(of: "Odstavec")[0].frame.minY >= image.maxY)
        #expect(changes == 0)
    }

    @Test("folding a heading hides its list; unfolding brings it back laid out the same")
    func folding() throws {
        let editor = try Editor("# Nadpis\n- první \(Self.long)\n  - druhá\n## Další\ntext", width: 340)
        let first = editor.x(ofItem: "první")
        let second = editor.x(ofItem: "druhá")
        let height = editor.textView.fittingHeight(forWidth: 340)

        editor.textView.setSelectedRange(NSRange(location: 2, length: 0))
        editor.textView.toggleHeadingFold(nil)
        #expect(editor.textView.fittingHeight(forWidth: 340) < height - 30)
        editor.textView.toggleHeadingFold(nil)
        editor.layout()

        #expect(abs(editor.textView.fittingHeight(forWidth: 340) - height) < 1)
        #expect(abs(editor.x(ofItem: "první") - first) < 0.5)
        #expect(abs(editor.x(ofItem: "druhá") - second) < 0.5)
        expectHangingIndent(of: "první", in: editor.textView)
        expectBullet(try Rendering(editor.textView).markerInk(of: "druhá", in: editor.textView))
    }

    private static func png() -> Data? {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 200, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )
        return bitmap?.representation(using: .png, properties: [:])
    }
}

// MARK: - Helpers

/// The text without the `‸` caret mark.
private func plain(_ text: String) -> String {
    text.replacingOccurrences(of: "‸", with: "")
}

/// A hosted editor with its own window and undo manager.
@MainActor
private final class Editor {
    let window: NSWindow
    let scrollView: NSScrollView
    let textView: MarkdownTextView
    let undoManager: UndoManager

    init(_ text: String, width: CGFloat = 700) throws {
        scrollView = MarkdownTextViewFactory.makeScrollView(style: .standard)
        textView = try #require(scrollView.documentView as? MarkdownTextView)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        scrollView.frame = window.contentLayoutRect
        undoManager = try #require(textView.undoManager)
        undoManager.groupsByEvent = false
        load(text)
    }

    /// Sets the text with the caret at `‸`, or at the end without one.
    func load(_ text: String) {
        let string = plain(text)
        textView.string = string
        let caret = (text as NSString).range(of: "‸").location
        textView.setSelectedRange(NSRange(location: caret == NSNotFound ? (string as NSString).length : caret, length: 0))
        layout()
    }

    /// The text with `‸` at the caret, or `[`…`]` around the selection.
    var marked: String {
        let result = NSMutableString(string: textView.string)
        let selection = textView.selectedRange()
        if selection.length == 0 {
            result.insert("‸", at: selection.location)
        } else {
            result.insert("]", at: selection.upperBound)
            result.insert("[", at: selection.location)
        }
        return result as String
    }

    /// Runs `action` as one user event: its own undo group.
    func event(_ action: () -> Void) {
        undoManager.beginUndoGrouping()
        action()
        undoManager.endUndoGrouping()
    }

    func enter() {
        event { textView.insertNewline(nil) }
    }

    /// How many text change notifications `action` sends.
    func changes(_ action: () -> Void) -> Int {
        var count = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: textView, queue: nil
        ) { _ in MainActor.assumeIsolated { count += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }
        action()
        return count
    }

    func layout() {
        window.contentView?.layoutSubtreeIfNeeded()
        textView.layoutSubtreeIfNeeded()
        if let manager = textView.textLayoutManager { manager.ensureLayout(for: manager.documentRange) }
    }

    func resize(width: CGFloat) {
        window.setContentSize(NSSize(width: width, height: 500))
        scrollView.frame = window.contentLayoutRect
        layout()
    }

    func zoom(fontSize: CGFloat) {
        textView.markdownStyle = MarkdownEditorStyle(fontName: "System", fontSize: fontSize)
        layout()
    }

    func x(of substring: String) -> CGFloat {
        Geometry.x(of: substring, in: textView)
    }

    /// Where the text of the item `text` starts (the first match of `text`).
    func x(ofItem text: String) -> CGFloat {
        Geometry.x(of: text, in: textView)
    }

    func lines(of substring: String) -> [Geometry.Line] {
        Geometry.lines(at: (textView.string as NSString).range(of: substring).location, in: textView)
    }
}

/// A read-only view in a window.
@MainActor
private func readOnlyView(_ text: String, width: CGFloat = 600) -> (NSWindow, MarkdownTextView) {
    let textView = MarkdownTextViewFactory.makeReadOnlyTextView()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 500))
    textView.frame = NSRect(x: 0, y: 0, width: width, height: 500)
    window.contentView?.addSubview(textView)
    textView.string = text
    if let manager = textView.textLayoutManager { manager.ensureLayout(for: manager.documentRange) }
    return (window, textView)
}

/// Where TextKit 2 lays characters out, in view coordinates.
@MainActor
private enum Geometry {
    struct Line {
        /// In the whole text.
        let range: NSRange
        let frame: NSRect
    }

    private static func fragment(at index: Int, in textView: NSTextView) -> (fragment: NSTextLayoutFragment, start: Int)? {
        guard let manager = textView.textLayoutManager,
              let location = manager.location(manager.documentRange.location, offsetBy: index) else { return nil }
        manager.ensureLayout(for: manager.documentRange)
        guard let fragment = manager.textLayoutFragment(for: location) else { return nil }
        return (fragment, manager.offset(from: manager.documentRange.location, to: fragment.rangeInElement.location))
    }

    /// The laid-out lines of the paragraph containing `index`.
    static func lines(at index: Int, in textView: NSTextView) -> [Line] {
        guard let (fragment, start) = fragment(at: index, in: textView) else { return [] }
        let origin = textView.textContainerOrigin
        let frame = fragment.layoutFragmentFrame
        return fragment.textLineFragments.map { line in
            let bounds = line.typographicBounds
            return Line(
                range: NSRange(location: start + line.characterRange.location, length: line.characterRange.length),
                frame: NSRect(x: origin.x + frame.minX + bounds.minX, y: origin.y + frame.minY + bounds.minY, width: bounds.width, height: bounds.height)
            )
        }
    }

    /// Where the character at `index` starts.
    static func x(at index: Int, in textView: NSTextView) -> CGFloat {
        guard let (fragment, start) = fragment(at: index, in: textView) else { return .nan }
        let local = index - start
        guard let line = fragment.textLineFragments.first(where: { NSLocationInRange(local, $0.characterRange) }) else { return .nan }
        return textView.textContainerOrigin.x + fragment.layoutFragmentFrame.minX + line.typographicBounds.minX
            + line.locationForCharacter(at: local).x
    }

    static func x(of substring: String, in textView: NSTextView) -> CGFloat {
        let found = (textView.string as NSString).range(of: substring)
        return found.location == NSNotFound ? .nan : x(at: found.location, in: textView)
    }
}

/// Checks that the item text starting with `text` has wrapped and that every
/// line of its paragraph starts where the text does. Returns that x.
@MainActor
@discardableResult
private func expectHangingIndent(of text: String, in textView: NSTextView, sourceLocation: SourceLocation = #_sourceLocation) -> CGFloat {
    let index = (textView.string as NSString).range(of: text).location
    let x = Geometry.x(at: index, in: textView)
    let lines = Geometry.lines(at: index, in: textView)
    #expect(lines.count >= 2, "\(text) does not wrap", sourceLocation: sourceLocation)
    for line in lines.dropFirst() {
        #expect(abs(Geometry.x(at: line.range.location, in: textView) - x) < 1, "\(text)", sourceLocation: sourceLocation)
    }
    return x
}

/// Checks that `ink` is a solid round bullet of a sensible size.
@MainActor
private func expectBullet(_ ink: NSRect?, fontSize: CGFloat = 15, sourceLocation: SourceLocation = #_sourceLocation) {
    guard let ink else {
        Issue.record("no bullet drawn", sourceLocation: sourceLocation)
        return
    }
    #expect(ink.width > fontSize * 0.2 && ink.width < fontSize * 0.55, "\(ink)", sourceLocation: sourceLocation)
    #expect(abs(ink.width - ink.height) <= 1, "\(ink)", sourceLocation: sourceLocation)
}

/// Checks that `ink`, a number, ends well before the text `item`.
@MainActor
private func expectNumber(_ ink: NSRect?, before item: String, in textView: NSTextView, sourceLocation: SourceLocation = #_sourceLocation) {
    guard let ink else {
        Issue.record("no number drawn before \(item)", sourceLocation: sourceLocation)
        return
    }
    let text = Geometry.x(of: item, in: textView)
    #expect(ink.width > 4 && ink.height > 6, "\(item) \(ink)", sourceLocation: sourceLocation)
    #expect(ink.maxX <= text - 3, "\(item) \(ink) text at \(text)", sourceLocation: sourceLocation)
    #expect(ink.minX >= 1, "\(item) \(ink)", sourceLocation: sourceLocation)
}

/// An offscreen rendering of a view.
@MainActor
private struct Rendering {
    let rep: NSBitmapImageRep
    let scale: CGFloat
    private let background: [Int]

    init(_ view: NSView) throws {
        rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        scale = CGFloat(rep.pixelsWide) / view.bounds.width
        background = Self.pixel(rep, rep.pixelsWide - 2, 2)
    }

    private static func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> [Int] {
        var pixel = [Int](repeating: 0, count: max(4, rep.samplesPerPixel))
        rep.getPixel(&pixel, atX: x, y: y)
        return pixel
    }

    private func isInk(_ x: Int, _ y: Int) -> Bool {
        zip(Self.pixel(rep, x, y), background).contains { abs($0 - $1) > 96 }
    }

    /// The bounds of what is drawn in `rect` (view coordinates), if anything.
    func ink(in rect: NSRect) -> NSRect? {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        let columns = max(0, Int(rect.minX * scale))..<min(rep.pixelsWide, Int((rect.maxX * scale).rounded(.up)))
        let rows = max(0, Int(rect.minY * scale))..<min(rep.pixelsHigh, Int((rect.maxY * scale).rounded(.up)))
        for y in rows {
            for x in columns where isInk(x, y) {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard minX <= maxX else { return nil }
        return NSRect(
            x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale
        )
    }

    /// What is drawn left of the item text at `index`, on its first line.
    func markerInk(at index: Int, in textView: NSTextView) -> NSRect? {
        guard let line = Geometry.lines(at: index, in: textView).first(where: { NSLocationInRange(index, $0.range) }) else { return nil }
        let text = Geometry.x(at: index, in: textView)
        return ink(in: NSRect(x: 0, y: line.frame.minY, width: text - 1, height: line.frame.height))
    }

    func markerInk(of item: String, in textView: NSTextView) -> NSRect? {
        markerInk(at: (textView.string as NSString).range(of: item).location, in: textView)
    }

    func matches(_ other: Rendering) -> Bool {
        guard rep.pixelsWide == other.rep.pixelsWide, rep.pixelsHigh == other.rep.pixelsHigh,
              rep.bytesPerRow == other.rep.bytesPerRow,
              let a = rep.bitmapData, let b = other.rep.bitmapData else { return false }
        return memcmp(a, b, rep.bytesPerRow * rep.pixelsHigh) == 0
    }
}
