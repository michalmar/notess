import AppKit
import NotessCore
import Testing
@testable import NotessEditor

/// Edit ▸ Kopírovat jako HTML in a real editor window. Every case writes to a
/// private pasteboard, except the one comparing it with ordinary Copy, which
/// restores the user's clipboard.
@MainActor
@Suite("Copy as HTML")
struct MarkdownTextViewCopyAsHTMLTests {
    @MainActor
    private final class Harness {
        let window: NSWindow
        let textView: MarkdownTextView
        let pasteboard: NSPasteboard
        let editMenu = NSMenu(title: "Úpravy")
        let copyAsHTMLItem = NSMenuItem(
            title: "Kopírovat jako HTML",
            action: #selector(MarkdownTextView.copyAsHTML(_:)),
            keyEquivalent: ""
        )
        var failures: [Error] = []

        enum Kind { case note, readOnly, brainNote }

        init(_ text: String, selecting selected: String? = nil, kind: Kind = .note) {
            pasteboard = .withUniqueName()
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            window.isReleasedWhenClosed = false
            if kind == .readOnly {
                textView = MarkdownTextViewFactory.makeReadOnlyTextView()
                window.contentView = textView
                textView.frame = window.contentLayoutRect
            } else {
                let scrollView = MarkdownTextViewFactory.makeScrollView()
                textView = scrollView.documentView as! MarkdownTextView
                window.contentView = scrollView
                scrollView.frame = window.contentLayoutRect
            }
            if kind == .brainNote { textView.isEditable = false }
            textView.string = text
            textView.noteURL = URL(filePath: "/NotessTests-nonexistent/Journal/2026/11/2026-11-02.md")
            textView.pasteboard = pasteboard
            textView.onCopyAsHTMLFailure = { [unowned self] in failures.append($0) }
            window.makeFirstResponder(textView)
            if let selected { select(selected) }
            editMenu.addItem(copyAsHTMLItem)
        }

        func close() {
            pasteboard.releaseGlobally()
            window.close()
        }

        func select(_ substring: String) {
            let range = (textView.string as NSString).range(of: substring)
            precondition(range.location != NSNotFound, "\(substring) not in the note")
            textView.setSelectedRange(range)
        }

        private func responderChainTarget(for action: Selector) -> AnyObject? {
            var responder: NSResponder? = window.firstResponder
            while let current = responder {
                if current.responds(to: action) { return current }
                responder = current.nextResponder
            }
            return nil
        }

        /// Whether Edit ▸ Kopírovat jako HTML is enabled, as validated by the menu.
        var isCopyAsHTMLEnabled: Bool {
            copyAsHTMLItem.target = responderChainTarget(for: #selector(MarkdownTextView.copyAsHTML(_:)))
            editMenu.update()
            return copyAsHTMLItem.isEnabled
        }

        /// Chooses Edit ▸ Kopírovat jako HTML when the menu enables it.
        func chooseCopyAsHTML() {
            guard isCopyAsHTMLEnabled else { return }
            editMenu.performActionForItem(at: editMenu.index(of: copyAsHTMLItem))
        }

        /// The context menu for a right-click on `substring`.
        func contextMenu(at substring: String) throws -> NSMenu {
            let range = (textView.string as NSString).range(of: substring)
            let rect = window.convertFromScreen(textView.firstRect(forCharacterRange: range, actualRange: nil))
            let event = try #require(NSEvent.mouseEvent(
                with: .rightMouseDown, location: NSPoint(x: rect.midX, y: rect.midY), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            return try #require(textView.menu(for: event))
        }

        /// Marks the clipboard so tests can tell it was left alone.
        func putPreviousClipboard() {
            pasteboard.clearContents()
            pasteboard.setString("předchozí obsah", forType: .string)
        }

        var clipboardIsUnchanged: Bool {
            pasteboard.string(forType: .string) == "předchozí obsah" && pasteboard.data(forType: .html) == nil
        }

        /// The copied rich and plain content.
        func copied() throws -> Copied {
            try Copied(pasteboard)
        }
    }

    /// The rich representation, parsed so tests can ask semantic questions.
    struct Copied {
        let html: String
        let plainText: String
        private let document: XMLDocument

        init(_ pasteboard: NSPasteboard) throws {
            let data = try #require(pasteboard.data(forType: .html))
            html = try #require(String(data: data, encoding: .utf8))
            plainText = try #require(pasteboard.string(forType: .string))
            document = try XMLDocument(xmlString: html, options: [.documentTidyHTML])
        }

        func nodes(_ xpath: String) -> [XMLNode] {
            (try? document.nodes(forXPath: xpath)) ?? []
        }

        func texts(_ xpath: String) -> [String] {
            nodes(xpath).map { ($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        }

        /// The text a rich-text recipient shows, whitespace as rendered.
        var rendered: String {
            let attributed = try? NSAttributedString(
                data: Data(html.utf8),
                options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil
            )
            return (attributed?.string ?? "").trimmingCharacters(in: .newlines)
        }

        /// The visible text of the body with whitespace collapsed.
        var visibleText: String {
            collapse(texts("//body").first ?? "")
        }

        func collapse(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }

    @Test("a word inside bold text copies as that bold word only")
    func wordInsideBold() throws {
        let harness = Harness("Před **tučný úsek textu** po", selecting: "úsek")
        defer { harness.close() }

        harness.chooseCopyAsHTML()

        let copied = try harness.copied()
        #expect(copied.texts("//strong | //b") == ["úsek"])
        #expect(copied.visibleText == "úsek")
        #expect(copied.plainText == "úsek")
        #expect(!copied.html.contains("**"))
    }

    @Test("the command is disabled without a selection and enabled with one")
    func availability() {
        let harness = Harness("Jen text")
        defer { harness.close() }

        harness.textView.setSelectedRange(NSRange(location: 3, length: 0))
        #expect(!harness.isCopyAsHTMLEnabled)
        harness.putPreviousClipboard()
        harness.textView.copyAsHTML(nil)
        #expect(harness.clipboardIsUnchanged)

        harness.select("text")
        #expect(harness.isCopyAsHTMLEnabled)
    }

    @Test("italic, strikethrough and inline code keep their formatting when selected partly")
    func partialInlineFormatting() throws {
        let harness = Harness(
            "Text *dlouhá kurzíva* a ~~přeškrtnuté slovo~~ a `swift  test` konec",
            selecting: "kurzíva* a ~~přeškrtnuté"
        )
        defer { harness.close() }

        harness.chooseCopyAsHTML()

        let copied = try harness.copied()
        #expect(copied.texts("//em | //i") == ["kurzíva"])
        #expect(copied.texts("//s | //del | //strike") == ["přeškrtnuté"])
        #expect(copied.visibleText == "kurzíva a přeškrtnuté")
        #expect(copied.plainText == "kurzíva a přeškrtnuté")
        #expect(copied.nodes("//p | //h1 | //li").isEmpty)

        harness.select("swift  te")
        harness.chooseCopyAsHTML()
        let code = try harness.copied()
        #expect(code.texts("//code") == ["swift te"])
        #expect(code.rendered == "swift  te")
        #expect(code.plainText == "swift  te")
    }

    @Test("a selection across lines is cut at the selection without leaking neighbouring text")
    func multiLineBoundaries() throws {
        let harness = Harness("Řádek jedna **tučně**\nŘádek dva pokračuje", selecting: "tučně**\nŘádek dva")
        defer { harness.close() }

        harness.chooseCopyAsHTML()

        let copied = try harness.copied()
        #expect(copied.texts("//strong | //b") == ["tučně"])
        #expect(copied.visibleText == "tučně Řádek dva")
        #expect(copied.plainText == "tučně\nŘádek dva")
    }

    @Test("headings and paragraphs export semantically without their markers")
    func headings() throws {
        let harness = Harness("# Hlavní nadpis\n\nOdstavec textu.\n\n### Menší nadpis")
        defer { harness.close() }
        harness.textView.selectAll(nil)

        harness.chooseCopyAsHTML()

        let copied = try harness.copied()
        #expect(copied.texts("//h1") == ["Hlavní nadpis"])
        #expect(copied.texts("//h3") == ["Menší nadpis"])
        #expect(copied.texts("//p") == ["Odstavec textu."])
        #expect(copied.plainText == "Hlavní nadpis\n\nOdstavec textu.\n\nMenší nadpis")
        #expect(!copied.html.contains("#"))
    }

    @Test("ordered, unordered and nested lists keep their structure")
    func lists() throws {
        let harness = Harness("- jedna\n- dva\n  - vnořená\n\n3. třetí\n4. čtvrtá")
        defer { harness.close() }
        harness.textView.selectAll(nil)

        harness.chooseCopyAsHTML()

        let copied = try harness.copied()
        #expect(copied.texts("/html/body/ul/li/text()").first == "jedna")
        #expect(copied.nodes("/html/body/ul/li").count == 2)
        #expect(copied.texts("//ul//ul/li") == ["vnořená"])
        #expect(copied.texts("//ol/li") == ["třetí", "čtvrtá"])
        #expect(copied.texts("//ol/@start") == ["3"])
        #expect(copied.plainText == "• jedna\n• dva\n    • vnořená\n3. třetí\n4. čtvrtá")
    }

    @Test("tasks show readable checked and unchecked markers")
    func tasks() throws {
        let harness = Harness("- [ ] koupit mléko\n- [x] zavolat Janě")
        defer { harness.close() }
        harness.textView.selectAll(nil)

        harness.chooseCopyAsHTML()

        let copied = try harness.copied()
        #expect(copied.texts("//li") == ["☐ koupit mléko", "☑ zavolat Janě"])
        #expect(copied.plainText == "• ☐ koupit mléko\n• ☑ zavolat Janě")
        #expect(!copied.html.contains("[x]") && !copied.html.contains("[ ]"))
    }

    @Test("block quotes export as quotes")
    func quotes() throws {
        let harness = Harness("Úvod\n> První řádek citátu\n> druhý **řádek**")
        defer { harness.close() }
        harness.select("První řádek citátu\n> druhý **řádek**")

        harness.chooseCopyAsHTML()

        let copied = try harness.copied()
        #expect(copied.collapse(copied.texts("//blockquote").first ?? "") == "První řádek citátu druhý řádek")
        #expect(copied.texts("//blockquote//strong") == ["řádek"])
        #expect(copied.visibleText == "První řádek citátu druhý řádek")
        #expect(copied.plainText == "    První řádek citátu\n    druhý řádek")
        #expect(!copied.html.contains("&gt;"))
    }

    @Test("web and email links become clickable displayed text")
    func links() throws {
        let harness = Harness("Viz [web](https://example.com/a?b=1&c=2), <jana@example.com> a https://notess.app/docs.")
        defer { harness.close() }
        harness.textView.selectAll(nil)

        harness.chooseCopyAsHTML()

        let copied = try harness.copied()
        #expect(copied.texts("//a") == ["web", "jana@example.com", "https://notess.app/docs"])
        #expect(copied.texts("//a/@href") == ["https://example.com/a?b=1&c=2", "mailto:jana@example.com", "https://notess.app/docs"])
        #expect(copied.plainText == "Viz web, jana@example.com a https://notess.app/docs.")
    }

    @Test("tables export as semantic tables")
    func tables() throws {
        let harness = Harness("Před\n\n| Jméno | Role |\n| --- | :-: |\n| Jana | **autorka** |\n\nPo")
        defer { harness.close() }
        harness.select("| Jméno | Role |\n| --- | :-: |\n| Jana | **autorka** |")

        harness.chooseCopyAsHTML()

        let copied = try harness.copied()
        #expect(copied.texts("//table//th") == ["Jméno", "Role"])
        #expect(copied.texts("//table//td") == ["Jana", "autorka"])
        #expect(copied.texts("//td/strong | //td/b") == ["autorka"])
        #expect(copied.plainText == "Jméno\tRole\nJana\tautorka")
        #expect(!copied.html.contains("---"))
    }

    @Test("code stays code with its whitespace when the fence is outside the selection")
    func codeBlockWithoutFence() throws {
        let harness = Harness("Ukázka:\n```swift\nfunc a() {\n    print(\"<b>\")\n}\n```\nKonec")
        defer { harness.close() }
        harness.select("func a() {\n    print(\"<b>\")")

        harness.chooseCopyAsHTML()

        let copied = try harness.copied()
        #expect(copied.nodes("//pre//code").map { $0.stringValue } == ["func a() {\n    print(\"<b>\")"])
        #expect(copied.nodes("//b").isEmpty)
        #expect(copied.plainText == "func a() {\n    print(\"<b>\")")
        #expect(!copied.html.contains("```") && !copied.html.contains("swift") && !copied.html.contains("Ukázka"))
    }

    @Test("tags stay text and wiki-links become readable labels")
    func tagsAndWikiLinks() throws {
        let harness = Harness("Hotovo #projekt, viz [[Projekt#Další kroky]] a [[#Úvod]] či [[Deník|dnes]].")
        defer { harness.close() }
        harness.textView.selectAll(nil)

        harness.chooseCopyAsHTML()

        let copied = try harness.copied()
        #expect(copied.nodes("//a").isEmpty)
        #expect(copied.plainText == "Hotovo #projekt, viz Projekt - Další kroky a Úvod či Deník|dnes.")
        #expect(copied.visibleText == copied.plainText)
    }

    @Test("front matter is left out")
    func frontMatter() throws {
        let harness = Harness("---\ntitle: Tajné\ntags: [a]\n---\n# Nadpis\nText")
        defer { harness.close() }
        harness.textView.selectAll(nil)

        harness.chooseCopyAsHTML()

        let copied = try harness.copied()
        #expect(copied.visibleText == "Nadpis Text")
        #expect(copied.plainText == "Nadpis\nText")
        #expect(!copied.html.contains("Tajné"))
    }

    @Test("a selection of front matter alone copies nothing")
    func nothingVisible() {
        let harness = Harness("---\ntitle: Tajné\n---\nText", selecting: "title: Tajné")
        defer { harness.close() }
        harness.putPreviousClipboard()

        harness.textView.copyAsHTML(nil)

        #expect(harness.clipboardIsUnchanged)
    }

    @Test("remote images become descriptions and are never referenced")
    func remoteImages() throws {
        let harness = Harness("Logo: ![Logo firmy](https://example.com/logo.png) a ![](http://example.com/x.png)")
        defer { harness.close() }
        harness.textView.selectAll(nil)

        harness.chooseCopyAsHTML()

        let copied = try harness.copied()
        #expect(copied.nodes("//img").isEmpty)
        #expect(!copied.html.contains("example.com"))
        #expect(copied.plainText == "Logo: [Obrázek: Logo firmy] a [Obrázek]")
        #expect(copied.visibleText == copied.plainText)
    }

    @Test("a local image fails clearly and leaves the clipboard and note unchanged")
    func localImage() throws {
        let note = "Text\n\n![Schéma](obrazky/schema.png)\n\nDalší"
        let harness = Harness(note)
        defer { harness.close() }
        harness.textView.selectAll(nil)
        harness.putPreviousClipboard()

        harness.chooseCopyAsHTML()

        #expect(harness.clipboardIsUnchanged)
        #expect(harness.textView.string == note)
        let error = try #require(harness.failures.first as? CopyAsHTMLError)
        #expect(error == .unsupportedLocalImage(source: "obrazky/schema.png"))
        #expect(error.localizedDescription.contains("obrazky/schema.png"))
    }

    @Test("rich and plain text carry the same mixed content")
    func richAndPlainCorrespond() throws {
        let note = """
        ## Plán
        Udělat **hodně** věcí, viz [web](https://example.com).
        - [x] první
        - druhý
        > citát
        """
        let harness = Harness(note)
        defer { harness.close() }
        harness.textView.selectAll(nil)

        harness.chooseCopyAsHTML()

        let copied = try harness.copied()
        #expect(copied.plainText == "Plán\nUdělat hodně věcí, viz web.\n• ☑ první\n• druhý\n    citát")
        #expect(copied.texts("//h2 | //p | //li") == ["Plán", "Udělat hodně věcí, viz web.", "☑ první", "druhý", "citát"])
        #expect(harness.textView.string == note)
    }

    @Test("the context menu offers the command after Copy and keeps a right-clicked selection")
    func contextMenuInsideSelection() throws {
        let harness = Harness("Před **tučný úsek** po", selecting: "tučný úsek")
        defer { harness.close() }

        let menu = try harness.contextMenu(at: "úsek")

        let copyIndex = try #require(menu.items.firstIndex { $0.action == #selector(NSText.copy(_:)) })
        let item = menu.items[copyIndex + 1]
        #expect(item.title == "Kopírovat jako HTML")
        #expect(item.keyEquivalent.isEmpty)
        menu.update()
        #expect(item.isEnabled)
        menu.performActionForItem(at: copyIndex + 1)
        #expect(try harness.copied().texts("//strong") == ["tučný úsek"])
    }

    @Test("a right-click outside the selection exports the resulting selection, not the old one")
    func contextMenuOutsideSelection() throws {
        let harness = Harness("**Vybraný** text a jinde", selecting: "Vybraný")
        defer { harness.close() }

        let menu = try harness.contextMenu(at: "jinde")

        let index = try #require(menu.items.firstIndex { $0.action == #selector(MarkdownTextView.copyAsHTML(_:)) })
        let resulting = (harness.textView.string as NSString).substring(with: harness.textView.selectedRange())
        menu.update()
        #expect(menu.items[index].isEnabled == !resulting.isEmpty)
        menu.performActionForItem(at: index)
        if resulting.isEmpty {
            #expect(harness.pasteboard.data(forType: .html) == nil)
        } else {
            let copied = try harness.copied()
            #expect(copied.plainText == resulting)
            #expect(copied.nodes("//strong").isEmpty)
            #expect(!copied.html.contains("Vybraný"))
        }
    }

    @Test("read-only Markdown and Brain Notes copy their selection", arguments: [false, true])
    func readOnly(isBrainNote: Bool) throws {
        let harness = Harness(
            "Odpověď s **důrazem** a `kódem`",
            selecting: "důrazem** a `kódem",
            kind: isBrainNote ? .brainNote : .readOnly
        )
        defer { harness.close() }

        #expect(harness.isCopyAsHTMLEnabled)
        harness.chooseCopyAsHTML()

        let copied = try harness.copied()
        #expect(copied.texts("//strong") == ["důrazem"])
        #expect(copied.texts("//code") == ["kódem"])
        #expect(try harness.contextMenu(at: "důrazem").items.contains { $0.action == #selector(MarkdownTextView.copyAsHTML(_:)) })
    }

    @Test("ordinary Copy still copies the Markdown source as plain text")
    func ordinaryCopyUnchanged() throws {
        let general = NSPasteboard.general
        let snapshot = ClipboardSnapshot(general)
        defer { snapshot.restore(to: general) }
        let harness = Harness("Před **tučně** po", selecting: "**tučně**")
        defer { harness.close() }

        harness.chooseCopyAsHTML()
        harness.textView.copy(nil)

        #expect(general.string(forType: .string) == "**tučně**")
        #expect(general.data(forType: .html) == nil)
        #expect(try harness.copied().texts("//strong") == ["tučně"])
    }
}

/// A copy of a pasteboard's items, written back after a test changes it.
@MainActor
private struct ClipboardSnapshot {
    private let items: [[(NSPasteboard.PasteboardType, Data)]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
