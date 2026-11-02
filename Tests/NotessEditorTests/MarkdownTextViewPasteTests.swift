import AppKit
import NotessCore
import SwiftUI
import Testing
@testable import NotessEditor

/// Cmd+V in a real editor window. Tests use a private pasteboard, except one
/// that needs the real clipboard (AppKit validates Paste against it) and
/// restores the user's clipboard contents afterwards.
@MainActor
@Suite("Clipboard paste")
struct MarkdownTextViewPasteTests {
    @MainActor
    private final class Harness {
        let window: NSWindow
        let textView: MarkdownTextView
        let pasteboard: NSPasteboard
        let editMenu = NSMenu(title: "Úpravy")
        let pasteItem = NSMenuItem(title: "Vložit", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let pasteAndMatchStyleItem = NSMenuItem(
            title: "Vložit a přizpůsobit styl",
            action: #selector(NSTextView.pasteAsPlainText(_:)),
            keyEquivalent: "v"
        )
        let coordinator = MarkdownEditor.Coordinator()
        var staged: [String: Data] = [:]
        var failures: [Error] = []
        var reportedTexts: [String] = []
        var changeNotifications = 0
        private var observer: NSObjectProtocol?

        init(_ text: String, selection: NSRange? = nil, pasteboard: NSPasteboard = .withUniqueName()) {
            self.pasteboard = pasteboard
            let scrollView = MarkdownTextViewFactory.makeScrollView()
            textView = scrollView.documentView as! MarkdownTextView
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            window.isReleasedWhenClosed = false
            window.contentView = scrollView
            scrollView.frame = window.contentLayoutRect
            textView.string = text
            textView.setSelectedRange(selection ?? NSRange(location: (text as NSString).length, length: 0))
            window.makeFirstResponder(textView)
            textView.pasteboard = pasteboard
            textView.noteURL = URL(filePath: "/NotessTests-nonexistent/Journal/2026/10/2026-10-15.md")
            textView.onPasteImage = { [unowned self] data, fileExtension in
                let path = "attachments/image-\(staged.count + 1).\(fileExtension)"
                staged[path] = data
                return "![](\(path))"
            }
            textView.inlineImageData = { [unowned self] in staged[$0] }
            textView.onPasteImageFailure = { [unowned self] in failures.append($0) }

            // The SwiftUI wrapper's delegate, which reports edits to the document.
            textView.delegate = coordinator
            coordinator.onTextChange = { [unowned self] in reportedTexts.append($0) }
            observer = NotificationCenter.default.addObserver(
                forName: NSText.didChangeNotification, object: textView, queue: nil
            ) { [unowned self] _ in MainActor.assumeIsolated { changeNotifications += 1 } }

            pasteItem.keyEquivalentModifierMask = .command
            pasteAndMatchStyleItem.keyEquivalentModifierMask = [.command, .option, .shift]
            editMenu.addItem(pasteItem)
            editMenu.addItem(pasteAndMatchStyleItem)
            textView.undoManager?.groupsByEvent = false
        }

        func close() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            if pasteboard != .general { pasteboard.releaseGlobally() }
            window.close()
        }

        /// The object AppKit sends a nil-targeted menu action to when this
        /// window is key: the first responder chain, then the window.
        private func responderChainTarget(for action: Selector) -> AnyObject? {
            var responder: NSResponder? = window.firstResponder
            while let current = responder {
                if current.responds(to: action) { return current }
                responder = current.nextResponder
            }
            return nil
        }

        /// Whether Edit ▸ Paste is enabled, as validated by the menu.
        var isPasteEnabled: Bool {
            pasteItem.target = responderChainTarget(for: #selector(NSText.paste(_:)))
            editMenu.update()
            return pasteItem.isEnabled
        }

        /// Whether Edit ▸ Paste and Match Style is enabled, as validated by the menu.
        var isPasteAndMatchStyleEnabled: Bool {
            pasteAndMatchStyleItem.target = responderChainTarget(for: #selector(NSTextView.pasteAsPlainText(_:)))
            editMenu.update()
            return pasteAndMatchStyleItem.isEnabled
        }

        /// Presses Cmd+V: the menu matches the key equivalent, validates the
        /// Paste item and sends `paste:` to the responder chain. One undo step.
        func pressCommandV() {
            pasteItem.target = responderChainTarget(for: #selector(NSText.paste(_:)))
            press(modifiers: .command)
        }

        /// Presses Option+Shift+Cmd+V, Paste and Match Style. One undo step.
        func pressPasteAndMatchStyle() {
            pasteAndMatchStyleItem.target = responderChainTarget(for: #selector(NSTextView.pasteAsPlainText(_:)))
            press(modifiers: [.command, .option, .shift])
        }

        private func press(modifiers: NSEvent.ModifierFlags) {
            let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "v",
                charactersIgnoringModifiers: "v",
                isARepeat: false,
                keyCode: 9
            )!
            textView.undoManager?.beginUndoGrouping()
            _ = editMenu.performKeyEquivalent(with: event)
            textView.undoManager?.endUndoGrouping()
        }

        func type(_ text: String) {
            textView.undoManager?.beginUndoGrouping()
            textView.insertText(text, replacementRange: textView.selectedRange())
            textView.undoManager?.endUndoGrouping()
        }

        func putPNG(_ data: Data) {
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .png)
        }

        /// An HTML clipboard, optionally with a plain-text representation of the same selection.
        func putHTML(_ html: String, plainText: String? = nil) {
            pasteboard.clearContents()
            pasteboard.setData(Data(html.utf8), forType: .html)
            if let plainText { pasteboard.setString(plainText, forType: .string) }
        }
    }

    @Test("Cmd+V is enabled for an image-only clipboard and inserts a standalone image", arguments: [
        ("", NSRange(location: 0, length: 0), "![](attachments/image-1.png)", 28),
        ("text", NSRange(location: 0, length: 0), "![](attachments/image-1.png)\ntext", 29),
        ("ab cd", NSRange(location: 2, length: 0), "ab\n![](attachments/image-1.png)\n cd", 32),
        ("text", NSRange(location: 4, length: 0), "text\n![](attachments/image-1.png)", 33),
        ("one\ntwo", NSRange(location: 4, length: 0), "one\n![](attachments/image-1.png)\ntwo", 33),
        ("keep REPLACE keep", NSRange(location: 5, length: 7), "keep \n![](attachments/image-1.png)\n keep", 35),
        ("REPLACE\nkeep", NSRange(location: 0, length: 7), "![](attachments/image-1.png)\nkeep", 28),
    ])
    func pasteImage(text: String, selection: NSRange, expected: String, caret: Int) throws {
        let harness = Harness(text, selection: selection)
        defer { harness.close() }
        let png = try #require(makePNG(width: 3, height: 2))
        harness.putPNG(png)

        #expect(harness.isPasteEnabled)
        harness.pressCommandV()

        #expect(harness.textView.string == expected)
        #expect(harness.textView.selectedRange() == NSRange(location: caret, length: 0))
        #expect(harness.staged == ["attachments/image-1.png": png])
        #expect(harness.failures.isEmpty)
    }

    @Test("Cmd+V pastes a screenshot from the real clipboard, which is then restored")
    func generalClipboard() throws {
        let general = NSPasteboard.general
        let saved = ClipboardSnapshot(general)
        defer { saved.restore(to: general) }

        let harness = Harness("Ráno", pasteboard: general)
        defer { harness.close() }
        general.clearContents()
        general.setData(try #require(makePNG(width: 2, height: 2)), forType: .png)

        // AppKit's own validation disables Paste here: a plain-text view reads no images.
        #expect(harness.isPasteEnabled)
        harness.pressCommandV()

        #expect(harness.textView.string == "Ráno\n![](attachments/image-1.png)")
        #expect(harness.staged.count == 1)
        #expect(harness.textView.displayedInlineImageCount == 1)
    }

    @Test("a pasted image renders inline at once from staged bytes and reports the edit")
    func pastedImageRendersAndNotifies() throws {
        let harness = Harness("Poznámka\n")
        defer { harness.close() }
        harness.putPNG(try #require(makePNG(width: 40, height: 20)))

        harness.pressCommandV()

        let expected = "Poznámka\n![](attachments/image-1.png)"
        #expect(harness.textView.string == expected)
        #expect(harness.textView.displayedInlineImageCount == 1)
        #expect(harness.changeNotifications == 1)
        #expect(harness.reportedTexts == [expected])
        #expect(FileManager.default.fileExists(atPath: "/NotessTests-nonexistent") == false)
    }

    @Test("a TIFF clipboard image is converted to a lossless PNG")
    func tiffIsConvertedToPNG() throws {
        let harness = Harness("")
        defer { harness.close() }
        let bitmap = try #require(makeBitmap(width: 5, height: 3))
        bitmap.setColor(NSColor(deviceRed: 1, green: 0.5, blue: 0.25, alpha: 1), atX: 1, y: 1)
        let tiff = try #require(bitmap.tiffRepresentation)
        harness.pasteboard.clearContents()
        harness.pasteboard.setData(tiff, forType: .tiff)

        #expect(harness.isPasteEnabled)
        harness.pressCommandV()

        #expect(harness.textView.string == "![](attachments/image-1.png)")
        let png = try #require(harness.staged["attachments/image-1.png"])
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let decoded = try #require(NSBitmapImageRep(data: png))
        #expect(decoded.pixelsWide == 5)
        #expect(decoded.pixelsHigh == 3)
        let pixel = try #require(decoded.colorAt(x: 1, y: 1))
        let original = try #require(bitmap.colorAt(x: 1, y: 1))
        #expect(pixel.redComponent == original.redComponent)
        #expect(pixel.greenComponent == original.greenComponent)
        #expect(pixel.blueComponent == original.blueComponent)
    }

    @Test("an image paste is undone and redone as one step")
    func undoRedo() throws {
        let harness = Harness("ab")
        defer { harness.close() }
        harness.type("c")
        harness.putPNG(try #require(makePNG(width: 2, height: 2)))
        harness.pressCommandV()
        let pasted = "abc\n![](attachments/image-1.png)"
        #expect(harness.textView.string == pasted)
        let undoManager = try #require(harness.textView.undoManager)

        undoManager.undo()
        #expect(harness.textView.string == "abc")
        #expect(harness.reportedTexts.last == "abc")
        #expect(harness.textView.displayedInlineImageCount == 0)

        undoManager.redo()
        #expect(harness.textView.string == pasted)
        #expect(harness.reportedTexts.last == pasted)
        #expect(harness.textView.displayedInlineImageCount == 1)

        undoManager.undo()
        undoManager.undo()
        #expect(harness.textView.string == "ab")
        #expect(harness.reportedTexts.last == "ab")
    }

    @Test("plain text pastes as before, even when an image preview comes with it")
    func textPaste() throws {
        let harness = Harness("before  after", selection: NSRange(location: 7, length: 0))
        defer { harness.close() }
        harness.pasteboard.clearContents()
        harness.pasteboard.setString("plain text", forType: .string)
        harness.pasteboard.setData(try #require(makePNG(width: 2, height: 2)), forType: .png)

        #expect(harness.isPasteEnabled)
        harness.pressCommandV()

        #expect(harness.textView.string == "before plain text after")
        #expect(harness.staged.isEmpty)
        #expect(harness.reportedTexts == ["before plain text after"])

        harness.textView.undoManager?.undo()
        #expect(harness.textView.string == "before  after")
    }

    @Test("Cmd+V pastes an HTML-only hyperlink as a Markdown link")
    func pasteHTMLLink() {
        let harness = Harness("")
        defer { harness.close() }
        harness.putHTML(#"<a href="https://example.com/docs">documentation</a>"#)

        #expect(harness.isPasteEnabled)
        harness.pressCommandV()

        #expect(harness.textView.string == "[documentation](https://example.com/docs)")
    }

    // MARK: HTML hyperlinks

    /// What WebKit (Safari, Mail) put on the clipboard for a selection of three
    /// paragraphs, as observed by a real copy; inline styles trimmed.
    private static let webKitCopy = """
        <head><meta charset="UTF-8"></head><p style="color: rgb(0, 0, 0);">See<span class="Apple-converted-space"> </span>\
        <a href="https://example.com/docs?a=1&amp;b=2">documentation</a><span class="Apple-converted-space"> </span>and\
        <span class="Apple-converted-space"> </span><a href="https://example.com/pricing">pricing</a>.</p>\
        <p style="color: rgb(0, 0, 0);">Mail<span class="Apple-converted-space"> </span><a href="mailto:team@example.com">the team</a>\
        <span class="Apple-converted-space"> </span>or visit<span class="Apple-converted-space"> </span>\
        <a href="https://example.com/x">https://example.com/x</a>.</p>\
        <p style="color: rgb(0, 0, 0);">Odd<span class="Apple-converted-space"> </span><a href="file:///etc/hosts">local</a>\
        <span class="Apple-converted-space"> </span><a>js</a><span class="Apple-converted-space"> </span>\
        <a href="https://example.com/wiki/Foo_(bar)">Foo (bar)</a>.</p>
        """

    @Test("several links, surrounding text and paragraph boundaries survive a WebKit copy")
    func webKitSelection() {
        let harness = Harness("")
        defer { harness.close() }
        harness.putHTML(Self.webKitCopy)

        harness.pressCommandV()

        #expect(harness.textView.string == """
            See [documentation](https://example.com/docs?a=1&b=2) and [pricing](https://example.com/pricing).

            Mail [the team](mailto:team@example.com) or visit https://example.com/x.

            Odd local js [Foo (bar)](https://example.com/wiki/Foo_(bar)).
            """)
    }

    @Test("Chromium's copy-link markup becomes a link", arguments: [false, true])
    func chromiumCopy(withPlainText: Bool) {
        let harness = Harness("")
        defer { harness.close() }
        harness.putHTML(
            #"<meta charset='utf-8'><div itemprop="teams-copy-link"><a href="https://teams.example.com/l/message/1?context=%7B%22a%22%3A1%7D&amp;x=2">Jan: Je to na Vás 🙂</a></div>"#,
            plainText: withPlainText ? "Jan: Je to na Vás 🙂" : nil
        )

        harness.pressCommandV()

        #expect(harness.textView.string == "[Jan: Je to na Vás 🙂](https://teams.example.com/l/message/1?context=%7B%22a%22%3A1%7D&x=2)")
    }

    @Test("Outlook-style markup keeps its links and drops office-only noise")
    func outlookStyleCopy() {
        let harness = Harness("")
        defer { harness.close() }
        harness.putHTML("""
            <html xmlns:o="urn:schemas-microsoft-com:office:office"><head><meta http-equiv=Content-Type content="text/html; charset=utf-8">\
            <style><!-- p.MsoNormal {margin:0cm} a:link {color:blue} --></style></head>\
            <body lang=CS><!--StartFragment--><div class=WordSection1>\
            <p class=MsoNormal>Dobrý den,<o:p></o:p></p><p class=MsoNormal><o:p>&nbsp;</o:p></p>\
            <p class=MsoNormal>viz <a href="https://example.com/a"><span style='color:#0563C1'>návod</span></a>.<o:p></o:p></p>\
            </div><!--EndFragment--></body></html>
            """)

        harness.pressCommandV()

        #expect(harness.textView.string == "Dobrý den,\n\nviz [návod](https://example.com/a).")
    }

    @Test("only valid absolute http, https and mailto destinations stay links", arguments: [
        (#"<a href="http://example.com/a">x</a>"#, "[x](http://example.com/a)"),
        (#"<a href="https://example.com/a">x</a>"#, "[x](https://example.com/a)"),
        (#"<a href="HTTPS://EXAMPLE.com/A">x</a>"#, "[x](HTTPS://EXAMPLE.com/A)"),
        (#"<a href="mailto:a@example.com">x</a>"#, "[x](mailto:a@example.com)"),
        (#"<a href="mailto:a@example.com?subject=Hi%20there">x</a>"#, "[x](mailto:a@example.com?subject=Hi%20there)"),
        (#"<a href="  https://example.com/a  ">x</a>"#, "[x](https://example.com/a)"),
        (#"<a href='https://example.com/a'>x</a>"#, "[x](https://example.com/a)"),
        (#"<A HREF=https://example.com/a>x</A>"#, "[x](https://example.com/a)"),
        (#"<a href="file:///etc/hosts">x</a> <a href="https://example.com/a">y</a>"#, "x [y](https://example.com/a)"),
        (#"<a href="javascript:alert(1)">x</a> <a href="https://example.com/a">y</a>"#, "x [y](https://example.com/a)"),
        (#"<a href="/relative">x</a> <a href="https://example.com/a">y</a>"#, "x [y](https://example.com/a)"),
        (#"<a href="//example.com/a">x</a> <a href="https://example.com/a">y</a>"#, "x [y](https://example.com/a)"),
        (#"<a href="example.com/a">x</a> <a href="https://example.com/a">y</a>"#, "x [y](https://example.com/a)"),
        (#"<a href="ftp://example.com/a">x</a> <a href="https://example.com/a">y</a>"#, "x [y](https://example.com/a)"),
        (#"<a href="tel:+420123456789">x</a> <a href="https://example.com/a">y</a>"#, "x [y](https://example.com/a)"),
        (#"<a href="https://">x</a> <a href="https://example.com/a">y</a>"#, "x [y](https://example.com/a)"),
        (#"<a href="mailto:">x</a> <a href="https://example.com/a">y</a>"#, "x [y](https://example.com/a)"),
        (#"<a href="">x</a> <a href="https://example.com/a">y</a>"#, "x [y](https://example.com/a)"),
        (#"<a name="top">x</a> <a href="https://example.com/a">y</a>"#, "x [y](https://example.com/a)"),
        (#"<a href="data:text/html,hi">x</a> <a href="https://example.com/a">y</a>"#, "x [y](https://example.com/a)"),
    ])
    func destinations(html: String, expected: String) {
        let harness = Harness("")
        defer { harness.close() }
        harness.putHTML(html)

        harness.pressCommandV()

        #expect(harness.textView.string == expected)
    }

    @Test("a clipboard with only unsupported destinations pastes its visible text", arguments: [
        #"<a href="file:///etc/hosts">local file</a>"#,
        #"<a href="javascript:void(0)">script</a> and <a href="/relative">relative</a>"#,
    ])
    func onlyUnsupportedDestinations(html: String) {
        let harness = Harness("")
        defer { harness.close() }
        harness.putHTML(html)
        let visible = html.replacing(/<[^>]*>/, with: "")

        harness.pressCommandV()

        #expect(harness.textView.string == visible)
    }

    @Test("a web link shown as its own destination stays a bare URL; any difference keeps both", arguments: [
        (#"go <a href="https://example.com/x">https://example.com/x</a> now"#, "go https://example.com/x now"),
        (#"<a href="https://example.com/x">https://example.com/x</a> <a href="https://example.com/y">y</a>"#, "https://example.com/x [y](https://example.com/y)"),
        (#"<a href="https://example.com/b">https://example.com/a</a>"#, "[https://example.com/a](https://example.com/b)"),
        (#"<a href="https://example.com/">https://example.com</a>"#, "[https://example.com](https://example.com/)"),
        (#"<a href="https://example.com/x">HTTPS://example.com/x</a>"#, "[HTTPS://example.com/x](https://example.com/x)"),
        (#"<a href="https://evil.example/r?u=https%3A%2F%2Fexample.com">https://example.com</a>"#, "[https://example.com](https://evil.example/r?u=https%3A%2F%2Fexample.com)"),
        (#"<a href="mailto:a@example.com">mailto:a@example.com</a>"#, "[mailto:a@example.com](mailto:a@example.com)"),
        (#"<a href="mailto:a@example.com">a@example.com</a>"#, "[a@example.com](mailto:a@example.com)"),
    ])
    func redundantWebLinks(html: String, expected: String) {
        let harness = Harness("")
        defer { harness.close() }
        harness.putHTML(html, plainText: expected)

        harness.pressCommandV()

        #expect(harness.textView.string == expected)
    }

    @Test("Markdown-sensitive labels and destinations keep their meaning", arguments: [
        (#"<a href="https://example.com/a">a*b_c [x] \ &lt;y&gt; `z` ~w~</a>"#, #"[a\*b\_c \[x\] \\ \<y\> \`z\` \~w\~](https://example.com/a)"#),
        (#"<a href="https://example.com/a">AT&amp;T &amp;copy; &amp;#35;</a>"#, #"[AT&T \&copy; \&#35;](https://example.com/a)"#),
        (#"<a href="https://example.com/a">two\#nlines</a>"#.replacingOccurrences(of: #"\#n"#, with: "\n   "), "[two lines](https://example.com/a)"),
        (#"<a href="https://example.com/a b">x</a>"#, "[x](https://example.com/a%20b)"),
        (#"<a href="https://example.com/a)b">x</a>"#, "[x](https://example.com/a%29b)"),
        (#"<a href="https://example.com/(a">x</a>"#, "[x](https://example.com/%28a)"),
        (#"<a href="https://example.com/a(b)c(d)">x</a>"#, "[x](https://example.com/a(b)c(d))"),
        (#"<a href="https://example.com/a&lt;b&gt;c\d">x</a>"#, "[x](https://example.com/a%3Cb%3Ec%5Cd)"),
        (#"<a href="https://example.com/čaj?x=1&amp;y=2#h">x</a>"#, "[x](https://example.com/čaj?x=1&y=2#h)"),
        (#"Wow!<a href="https://example.com/a">link</a>"#, #"Wow\![link](https://example.com/a)"#),
    ])
    func markdownSensitive(html: String, expected: String) {
        let harness = Harness("")
        defer { harness.close() }
        harness.putHTML(html)

        harness.pressCommandV()

        #expect(harness.textView.string == expected)
    }

    @Test("other formatting adds no Markdown; tables and lists become plain lines", arguments: [
        (#"<b>bold</b> <i>it</i> <u>u</u> <span style="color:red">red</span> <a href="https://e.com/a"><b>Link</b></a>"#, "bold it u red [Link](https://e.com/a)"),
        ("<table><tr><td>a</td><td><a href=\"https://e.com/a\">b</a></td></tr><tr><td>c</td><td>d</td></tr></table>", "a [b](https://e.com/a)\nc d"),
        (#"<h1>Title</h1><ul><li>one <a href="https://e.com/a">two</a></li><li>three</li></ul>"#, "Title\n\none [two](https://e.com/a)\nthree"),
        (#"line<br>break<br><br>blank <a href="https://e.com/a">x</a>"#, "line\nbreak\n\nblank [x](https://e.com/a)"),
        (#"<div>a</div><div><br></div><div><a href="https://e.com/a">b</a></div>"#, "a\n\n[b](https://e.com/a)"),
        (#"<style>a{color:red}</style><script>var a = "<a href='https://e.com/s'>s</a>";</script><!-- <a href="https://e.com/c">c</a> -->t <a href="https://e.com/a">x</a>"#, "t [x](https://e.com/a)"),
        (#"<pre>  keep\n  this</pre> <a href="https://e.com/a">x</a>"#.replacingOccurrences(of: #"\n"#, with: "\n"), "  keep\n  this\n\n[x](https://e.com/a)"),
        (#"1 &lt; 2 &amp;&amp; 3 &gt; 2&nbsp;&#x2713; &quot;q&quot; <a href="https://e.com/a">x</a>"#, #"1 < 2 && 3 > 2 ✓ "q" [x](https://e.com/a)"#),
        (#"<a href="https://e.com/a"><img src="https://tracker.example/p.png"></a>text"#, "text"),
    ])
    func otherFormatting(html: String, expected: String) {
        let harness = Harness("")
        defer { harness.close() }
        harness.putHTML(html)

        harness.pressCommandV()

        #expect(harness.textView.string == expected)
    }

    @Test("HTML without hyperlinks pastes as ordinary text")
    func htmlWithoutLinks() {
        let withText = Harness("")
        defer { withText.close() }
        withText.putHTML("<p><b>Bold</b> and <i>italic</i></p>", plainText: "Bold and italic")
        withText.pressCommandV()
        #expect(withText.textView.string == "Bold and italic")

        let htmlOnly = Harness("")
        defer { htmlOnly.close() }
        htmlOnly.putHTML("<span><b>Bold</b> and <i>italic</i></span>")
        #expect(htmlOnly.isPasteEnabled)
        htmlOnly.pressCommandV()
        #expect(htmlOnly.textView.string == "Bold and italic")
    }

    @Test("HTML and plain text of the same selection paste once")
    func htmlAndPlainTextPasteOnce() {
        let harness = Harness("")
        defer { harness.close() }
        harness.putHTML(
            #"<p>See <a href="https://example.com/docs">documentation</a></p>"#,
            plainText: "See documentation"
        )

        harness.pressCommandV()

        #expect(harness.textView.string == "See [documentation](https://example.com/docs)")
        #expect(harness.changeNotifications == 1)
    }

    @Test("HTML decodes from UTF-8 with a BOM, UTF-16 and a declared legacy charset")
    func htmlEncodings() throws {
        let html = #"<meta charset="UTF-8"><a href="https://example.com/a">Čaj</a>"#
        let encodings: [(String, Data)] = [
            ("utf8 bom", Data([0xEF, 0xBB, 0xBF]) + Data(html.utf8)),
            ("utf16 bom", try #require(("\u{FEFF}" + html).data(using: .utf16LittleEndian))),
            ("utf16 big endian", try #require(("\u{FEFF}" + html).data(using: .utf16BigEndian))),
            ("cp1250", try #require(html.replacing("UTF-8", with: "windows-1250").data(using: .windowsCP1250))),
        ]
        for (name, data) in encodings {
            let harness = Harness("")
            defer { harness.close() }
            harness.pasteboard.clearContents()
            harness.pasteboard.setData(data, forType: .html)

            harness.pressCommandV()

            #expect(harness.textView.string == "[Čaj](https://example.com/a)", Comment(rawValue: name))
        }
    }

    @Test("a link paste replaces the selection, leaves the caret after it and reports one edit")
    func replacesSelectionAndNotifies() {
        let harness = Harness("keep REPLACE keep", selection: NSRange(location: 5, length: 7))
        defer { harness.close() }
        harness.putHTML(#"<a href="https://example.com/a">new</a>"#)

        harness.pressCommandV()

        let expected = "keep [new](https://example.com/a) keep"
        #expect(harness.textView.string == expected)
        #expect(harness.textView.selectedRange() == NSRange(location: 33, length: 0))
        #expect(harness.changeNotifications == 1)
        #expect(harness.reportedTexts == [expected])
        #expect(harness.staged.isEmpty)
    }

    @Test("a link paste is undone and redone as one step without merging an earlier edit")
    func linkPasteUndoRedo() throws {
        let harness = Harness("ab")
        defer { harness.close() }
        harness.type("c")
        harness.putHTML(#"x <a href="https://example.com/a">y</a>"#)
        harness.pressCommandV()
        let pasted = "abcx [y](https://example.com/a)"
        #expect(harness.textView.string == pasted)
        let undoManager = try #require(harness.textView.undoManager)

        undoManager.undo()
        #expect(harness.textView.string == "abc")
        #expect(harness.reportedTexts.last == "abc")

        undoManager.redo()
        #expect(harness.textView.string == pasted)
        #expect(harness.reportedTexts.last == pasted)

        undoManager.undo()
        undoManager.undo()
        #expect(harness.textView.string == "ab")
        #expect(harness.reportedTexts.last == "ab")
    }

    @Test("Paste and Match Style inserts only the visible text when links are present", arguments: [
        (#"<p>See <a href="https://example.com/docs">documentation</a></p>"#, "See documentation" as String?),
        (#"<p>See <a href="https://example.com/docs">documentation</a></p>"#, nil),
    ])
    func pasteAndMatchStyle(html: String, plainText: String?) {
        let harness = Harness("a ")
        defer { harness.close() }
        harness.putHTML(html, plainText: plainText)

        #expect(harness.isPasteAndMatchStyleEnabled)
        harness.pressPasteAndMatchStyle()

        #expect(harness.textView.string == "a See documentation")
        #expect(harness.textView.selectedRange() == NSRange(location: 19, length: 0))
        #expect(harness.reportedTexts == ["a See documentation"])
        harness.textView.undoManager?.undo()
        #expect(harness.textView.string == "a ")
    }

    @Test("Paste and Match Style stays disabled in a read-only editor or for an empty clipboard")
    func pasteAndMatchStyleDisabled() {
        let readOnly = Harness("Brain Note")
        defer { readOnly.close() }
        readOnly.textView.isEditable = false
        readOnly.putHTML(#"<a href="https://example.com/a">x</a>"#, plainText: "x")
        #expect(readOnly.isPasteAndMatchStyleEnabled == false)

        let empty = Harness("")
        defer { empty.close() }
        empty.pasteboard.clearContents()
        #expect(empty.isPasteAndMatchStyleEnabled == false)
    }

    @Test("a read-only editor or an empty clipboard ignores HTML links")
    func linkPasteRestrictions() {
        let readOnly = Harness("Brain Note")
        defer { readOnly.close() }
        readOnly.textView.isEditable = false
        readOnly.putHTML(#"<a href="https://example.com/a">x</a>"#)
        #expect(readOnly.isPasteEnabled == false)
        readOnly.textView.paste(nil)
        #expect(readOnly.textView.string == "Brain Note")
        #expect(readOnly.changeNotifications == 0)

        let empty = Harness("keep")
        defer { empty.close() }
        empty.pasteboard.clearContents()
        #expect(empty.isPasteEnabled == false)
        empty.pressCommandV()
        #expect(empty.textView.string == "keep")
        #expect(empty.changeNotifications == 0)
    }

    @Test("plain text, bare URLs and Markdown source paste unchanged", arguments: [
        "just words",
        "https://example.com/a",
        "[docs](https://example.com/a) and [[Note]] #tag",
    ])
    func plainTextUnchanged(text: String) {
        let harness = Harness("")
        defer { harness.close() }
        harness.pasteboard.clearContents()
        harness.pasteboard.setString(text, forType: .string)

        harness.pressCommandV()

        #expect(harness.textView.string == text)
    }

    @Test("a link with an image preview pastes as text; a linked image alone still attaches")
    func linkAndImagePreview() throws {
        let png = try #require(makePNG(width: 2, height: 2))
        let withText = Harness("")
        defer { withText.close() }
        withText.putHTML(#"<a href="https://example.com/a">label</a>"#, plainText: "label")
        withText.pasteboard.setData(png, forType: .png)
        withText.pressCommandV()
        #expect(withText.textView.string == "[label](https://example.com/a)")
        #expect(withText.staged.isEmpty)

        let imageOnly = Harness("")
        defer { imageOnly.close() }
        imageOnly.putHTML(#"<a href="https://example.com/a"><img src="https://example.com/p.png"></a>"#)
        imageOnly.pasteboard.setData(png, forType: .png)
        imageOnly.pressCommandV()
        #expect(imageOnly.textView.string == "![](attachments/image-1.png)")
        #expect(imageOnly.staged.count == 1)
    }

    @Test("nothing is fetched or opened when a link is pasted")
    func pasteDoesNotTouchTheNetwork() {
        let harness = Harness("")
        defer { harness.close() }
        harness.putHTML(#"<link rel="stylesheet" href="https://example.invalid/s.css"><a href="https://example.invalid/a"><img src="https://example.invalid/p.png">x</a>"#)

        harness.pressCommandV()

        #expect(harness.textView.string == "[x](https://example.invalid/a)")
    }

    @Test("ordinary Paste and Paste and Match Style handle links on the real clipboard, which is then restored")
    func generalClipboardLinks() {
        let general = NSPasteboard.general
        let saved = ClipboardSnapshot(general)
        defer { saved.restore(to: general) }

        let harness = Harness("", pasteboard: general)
        defer { harness.close() }
        general.clearContents()
        general.setData(Data(Self.webKitCopy.utf8), forType: .html)

        #expect(harness.isPasteEnabled)
        #expect(harness.isPasteAndMatchStyleEnabled)
        harness.pressCommandV()
        #expect(harness.textView.string.hasPrefix("See [documentation](https://example.com/docs?a=1&b=2) and [pricing]"))

        harness.textView.string = ""
        harness.textView.setSelectedRange(NSRange(location: 0, length: 0))
        harness.pressPasteAndMatchStyle()
        #expect(harness.textView.string.hasPrefix("See documentation and pricing.\n"))
        #expect(harness.textView.string.contains("](") == false)
    }

    @Test("an unreadable clipboard image is reported and inserts nothing")
    func unreadableImage() {
        let harness = Harness("text")
        defer { harness.close() }
        harness.putPNG(Data("not an image".utf8))

        #expect(harness.isPasteEnabled)
        harness.pressCommandV()

        #expect(harness.textView.string == "text")
        #expect(harness.staged.isEmpty)
        #expect(harness.failures.map { $0 as? ImagePasteError } == [.unreadableImage])
        #expect(harness.changeNotifications == 0)
    }

    @Test("Paste stays disabled where an image cannot go")
    func pasteDisabled() throws {
        let png = try #require(makePNG(width: 2, height: 2))

        let readOnly = Harness("Brain Note")
        defer { readOnly.close() }
        readOnly.textView.isEditable = false
        readOnly.putPNG(png)
        #expect(readOnly.isPasteEnabled == false)

        let noHandler = Harness("")
        defer { noHandler.close() }
        noHandler.textView.onPasteImage = nil
        noHandler.putPNG(png)
        #expect(noHandler.isPasteEnabled == false)

        let emptyClipboard = Harness("")
        defer { emptyClipboard.close() }
        emptyClipboard.pasteboard.clearContents()
        #expect(emptyClipboard.isPasteEnabled == false)
    }

    @Test("a file copied in Finder is not pasted as an image")
    func fileURLIsNotAnImage() throws {
        let harness = Harness("")
        defer { harness.close() }
        harness.pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(URL(filePath: "/tmp/screenshot.png").absoluteString, forType: .fileURL)
        item.setData(try #require(makeBitmap(width: 2, height: 2)?.tiffRepresentation), forType: .tiff)
        harness.pasteboard.writeObjects([item])

        harness.pressCommandV()

        #expect(harness.staged.isEmpty)
        #expect(harness.textView.string.contains("![](") == false)
    }

    /// The SwiftUI editor wired to a `NoteDocument` like the app's editor screen.
    @Test("pasting into the hosted editor stages the image until explicit save")
    func hostedEditorStagesUntilSave() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "NotessEditorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let noteURL = root.appending(path: "Journal/2026/10/2026-10-15.md")
        let document = try NoteDocument.open(fileURL: noteURL, newFileContent: "# 15. 10. 2026\n")
        var failures: [Error] = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        func host() throws -> MarkdownTextView {
            window.contentView = NSHostingView(rootView: MarkdownEditor(
                documentID: UUID(),
                initialText: { document.text },
                noteURL: document.fileURL,
                onPasteImage: { data, fileExtension in
                    document.stageAttachment(data: data, fileExtension: fileExtension).markdown
                },
                onPasteImageFailure: { failures.append($0) },
                inlineImageData: { document.stagedAttachmentData(relativePath: $0) },
                onTextChange: { document.text = $0 }
            ))
            window.contentView?.layoutSubtreeIfNeeded()
            let textView = try #require(window.contentView?.firstSubview(of: MarkdownTextView.self))
            window.makeFirstResponder(textView)
            return textView
        }
        let textView = try host()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        textView.pasteboard = pasteboard
        let png = try #require(makePNG(width: 8, height: 4))
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        let item = NSMenuItem(title: "Vložit", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        #expect(textView.validateMenuItem(item))

        NSApp.sendAction(#selector(NSText.paste(_:)), to: textView, from: item)

        let link = try #require(textView.string.firstMatch(of: /!\[\]\((attachments\/image-[0-9a-f-]+\.png)\)/))
        let relativePath = String(link.output.1)
        #expect(textView.string == "# 15. 10. 2026\n\(link.output.0)")
        #expect(document.text == textView.string)
        #expect(document.hasUnsavedChanges)
        #expect(textView.displayedInlineImageCount == 1)
        #expect(FileManager.default.fileExists(atPath: root.path) == false)
        #expect(failures.isEmpty)

        try document.save()

        let imageURL = noteURL.deletingLastPathComponent().appending(path: relativePath)
        #expect(try Data(contentsOf: imageURL) == png)
        #expect(try String(contentsOf: noteURL, encoding: .utf8) == document.text)

        let reopened = try NoteDocument.open(fileURL: noteURL, newFileContent: "")
        let reopenedView = MarkdownTextViewFactory.makeScrollView().documentView as! MarkdownTextView
        window.contentView = reopenedView.enclosingScrollView
        reopenedView.string = reopened.text
        reopenedView.noteURL = noteURL
        reopenedView.inlineImageData = { reopened.stagedAttachmentData(relativePath: $0) }
        reopenedView.refreshInlineImages()
        #expect(reopenedView.displayedInlineImageCount == 1)
    }
}

private func makeBitmap(width: Int, height: Int) -> NSBitmapImageRep? {
    NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )
}

private func makePNG(width: Int, height: Int) -> Data? {
    makeBitmap(width: width, height: height)?.representation(using: .png, properties: [:])
}

private extension NSView {
    func firstSubview<T: NSView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T ?? subview.firstSubview(of: type) { return match }
        }
        return nil
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
