import AppKit
import NotessCore
import Testing
@testable import NotessEditor

@MainActor
@Suite("Source Task checkboxes")
struct TaskCheckboxTests {
    @Test("a recognizable checkbox stays drawn while typing on its Task line", arguments: [NSAppearance.Name.aqua, .darkAqua])
    func checkboxWhileTyping(appearance: NSAppearance.Name) throws {
        let editor = try CheckboxEditor("- [ ] koupit mléko")
        editor.textView.appearance = NSAppearance(named: appearance)
        let box = try #require(editor.checkboxes.first)
        #expect(box.accessibilityRole() == .checkBox)
        #expect(box.state == .off)
        #expect(editor.hasInk(in: box))
        #expect(editor.textView.textStorage?.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor == .clear)
        #expect(!editor.undoManager.canUndo)

        editor.event {
            editor.textView.insertText(" dnes", replacementRange: editor.textView.selectedRange())
        }

        editor.layout()

        let edited = try #require(editor.checkboxes.first)
        #expect(editor.hasInk(in: edited))
        #expect(edited.state == .off)
        #expect(editor.textView.string == "- [ ] koupit mléko dnes")
        #expect(editor.textView.selectedRange() == NSRange(location: 23, length: 0))
        #expect(editor.textView.textLayoutManager != nil)
    }

    @Test("the actual checkbox alone toggles, preserving source, nested states, selection and Undo", arguments: ["x", "X"])
    func actualHitAndUndo(mark: String) throws {
        let source = "- [ ] rodič\n  03)\t[\(mark)]\t🧠 [[Plán]] [web](https://x.cz)\n  * [x] sourozenec"
        let reopened = "- [ ] rodič\n  03)\t[ ]\t🧠 [[Plán]] [web](https://x.cz)\n  * [x] sourozenec"
        let editor = try CheckboxEditor(source)
        let selection = NSRange(location: 6, length: 3)
        editor.textView.setSelectedRange(selection)
        var changes = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: editor.textView, queue: nil
        ) { _ in MainActor.assumeIsolated { changes += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }
        let child = try #require(editor.checkboxes.dropFirst().first)

        #expect(!editor.textView.toggleTask(atPoint: editor.center(of: "🧠")))
        #expect(!editor.textView.pointingHandTarget(containing: editor.center(of: "🧠")))
        #expect(editor.textView.pointingHandTarget(containing: child.frame.center))
        try editor.click(child)

        #expect(editor.textView.string == reopened)
        #expect(editor.textView.selectedRange() == selection)
        #expect(editor.window.firstResponder === editor.textView)
        #expect(editor.checkboxes.map(\.state) == [.off, .off, .on])
        #expect(editor.attribute(.strikethroughStyle, at: "🧠") == nil)
        #expect(editor.attribute(.strikethroughStyle, at: "sourozenec") as? Int == NSUnderlineStyle.single.rawValue)
        #expect(changes == 1)

        editor.undoManager.undo()
        editor.layout()
        #expect(editor.textView.string == source)
        #expect(editor.checkboxes.map(\.state) == [.off, .on, .on])
        #expect(changes == 2)
        editor.undoManager.redo()
        editor.layout()
        #expect(editor.textView.string == reopened)
        #expect(changes == 3)
    }

    @Test("checkbox accessibility exposes label and state and activates without taking editor focus")
    func accessibility() throws {
        let editor = try CheckboxEditor("- [ ] zavolat mámě")
        let box = try #require(editor.checkboxes.first)
        #expect(box.accessibilityRole() == .checkBox)
        #expect(box.accessibilityLabel() == "zavolat mámě")
        #expect(box.accessibilityValue() as? Int == 0)
        #expect(editor.textView.accessibilityChildren()?.contains { ($0 as? NSButton) === box } == true)
        #expect(!box.acceptsFirstResponder)
        editor.event { #expect(box.accessibilityPerformPress()) }
        editor.layout()
        #expect(editor.textView.string == "- [x] zavolat mámě")
        #expect(box.accessibilityValue() as? Int == 1)
        #expect(editor.window.firstResponder === editor.textView)
    }

    @Test("a real source note stays clean during presentation, tracks checkbox Undo, and writes only on explicit save")
    func explicitSave() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "NotessCheckbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "2026-11-05.md")
        let source = "# Den\n\n- [ ] zavolat 🧠\n"
        let completed = "# Den\n\n- [x] zavolat 🧠\n"
        try Data(source.utf8).write(to: url)
        let note = try NoteDocument.open(fileURL: url, newFileContent: "")
        let editor = try CheckboxEditor(note.text)
        let coordinator = MarkdownEditor.Coordinator()
        coordinator.onTextChange = { note.text = $0 }
        editor.textView.delegate = coordinator
        let box = try #require(editor.checkboxes.first)

        for location in [0, 10, 15, (source as NSString).length] {
            editor.textView.setSelectedRange(NSRange(location: location, length: 0))
            editor.layout()
        }
        editor.window.makeFirstResponder(nil)
        editor.window.makeFirstResponder(editor.textView)
        editor.textView.markdownStyle = MarkdownEditorStyle(fontName: "System", fontSize: 20)
        editor.layout()
        #expect(note.text == source)
        #expect(!note.hasUnsavedChanges)
        #expect(!editor.undoManager.canUndo)
        #expect(try String(contentsOf: url, encoding: .utf8) == source)

        try editor.click(box)
        #expect(note.text == completed)
        #expect(note.hasUnsavedChanges)
        #expect(try String(contentsOf: url, encoding: .utf8) == source)
        editor.undoManager.undo()
        #expect(note.text == source)
        #expect(!note.hasUnsavedChanges)
        editor.undoManager.redo()
        #expect(note.text == completed)
        #expect(note.hasUnsavedChanges)
        #expect(try String(contentsOf: url, encoding: .utf8) == source)

        try note.save()
        #expect(try String(contentsOf: url, encoding: .utf8) == completed)
        #expect(!note.hasUnsavedChanges)
        editor.undoManager.undo()
        #expect(note.text == source)
        #expect(note.hasUnsavedChanges)
        #expect(try String(contentsOf: url, encoding: .utf8) == completed)
    }

    @Test("wrapped Unicode Tasks keep separate checkbox targets after scrolling and text zoom", arguments: [7.5, 15.0, 30.0])
    func wrappingAndScrolling(size: Double) throws {
        let line = "- [ ] 🧠 žluťoučký kůň " + String(repeating: "dlouhý text ", count: 8)
        let source = (0..<40).map { "\(line) \($0)" }.joined(separator: "\n")
        let editor = try CheckboxEditor(source, width: 300)
        editor.textView.markdownStyle = MarkdownEditorStyle(fontName: "System", fontSize: size)
        editor.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        editor.layout()
        let first = try #require(editor.checkboxes.first)
        #expect(editor.hasInk(in: first))
        #expect(editor.checkboxes.count < 40)
        let firstFrame = first.frame
        let textRange = (source as NSString).range(of: "🧠")
        let lineFrame = editor.textView.rect(forCharacterRange: textRange)
        #expect(first.frame.minY >= lineFrame.minY - 0.5)
        #expect(first.frame.maxY <= lineFrame.maxY + 0.5)

        let last = (source as NSString).range(of: " 39", options: .backwards)
        let lastLine = (source as NSString).lineRange(for: last)
        editor.textView.scrollRangeToVisible(NSRange(location: lastLine.location + 2, length: 3))
        editor.layout()
        let bottom = try #require(editor.checkboxes.last)
        #expect(editor.hasInk(in: bottom))
        #expect(bottom.frame.minY > firstFrame.maxY)
        #expect(!editor.textView.pointingHandTarget(containing: firstFrame.center))
        #expect(editor.checkboxes.count < 40)
        try editor.click(bottom)
        #expect(editor.textView.string.hasSuffix("\(line.replacingOccurrences(of: "[ ]", with: "[x]")) 39"))
        #expect(editor.textView.string.hasPrefix("\(line) 0"))
        #expect(editor.textView.textLayoutManager != nil)
    }

    @Test("only supported Tasks get controls and read-only presentations never toggle", arguments: [true, false])
    func recognitionAndReadOnly(editable: Bool) throws {
        let source = """
            prose [ ] not a Task
            `- [ ] inline code`
            ```
            - [ ] fenced code
            ```

                - [ ] indented code

            - [X] skutečný úkol
            """
        let editor = try CheckboxEditor(source)
        editor.textView.isEditable = editable
        editor.layout()
        try #require(editor.checkboxes.count == 1)
        let box = try #require(editor.checkboxes.first)
        #expect(box.isEnabled == editable)
        #expect(box.state == .on)
        if !editable {
            #expect(!box.accessibilityPerformPress())
            #expect(!editor.textView.toggleTask(atPoint: box.frame.center))
            #expect(!editor.textView.pointingHandTarget(containing: box.frame.center))
        }
        #expect(editor.textView.string == source)
        #expect(!editor.undoManager.canUndo)
    }

    @Test("typing and deleting a Task marker adds and removes its checkbox with no stale hit target")
    func editingMarker() throws {
        let editor = try CheckboxEditor("- ")
        #expect(editor.checkboxes.isEmpty)
        editor.event {
            editor.textView.insertText("[ ] úkol", replacementRange: editor.textView.selectedRange())
        }
        editor.layout()
        let box = try #require(editor.checkboxes.first)
        let point = box.frame.center
        #expect(editor.hasInk(in: box))
        editor.textView.setSelectedRange(NSRange(location: 2, length: 3))
        editor.event { editor.textView.insertText("text", replacementRange: editor.textView.selectedRange()) }
        editor.layout()
        #expect(editor.checkboxes.isEmpty)
        #expect(!editor.textView.toggleTask(atPoint: point))
        #expect(!editor.textView.pointingHandTarget(containing: point))
        #expect(editor.textView.string == "- text úkol")
        editor.undoManager.undo()
        editor.layout()
        #expect(editor.checkboxes.count == 1)
        #expect(editor.textView.string == "- [ ] úkol")
    }

    @Test("Task text stays outside the checkbox target and remains ordinarily editable")
    func clickingTaskText() throws {
        let editor = try CheckboxEditor("- [ ] koupit mléko")
        let point = editor.center(of: "koupit")
        #expect(!editor.textView.toggleTask(atPoint: point))
        editor.textView.setSelectedRange(NSRange(location: 9, length: 0))
        let selection = editor.textView.selectedRange()
        #expect(selection.length == 0)
        #expect(selection.location >= 6 && selection.location <= 12)
        #expect(editor.textView.string == "- [ ] koupit mléko")
        #expect(!editor.undoManager.canUndo)
        editor.event { editor.textView.insertText("X", replacementRange: selection) }
        #expect(editor.textView.string.hasPrefix("- [ ] "))
        #expect(editor.textView.string.contains("X"))
    }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}

@MainActor
final class CheckboxEditor {
    let window: NSWindow
    let scrollView: NSScrollView
    let textView: MarkdownTextView
    let undoManager: UndoManager

    init(_ text: String, width: CGFloat = 600) throws {
        scrollView = MarkdownTextViewFactory.makeScrollView()
        textView = try #require(scrollView.documentView as? MarkdownTextView)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 300),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        scrollView.frame = window.contentLayoutRect
        undoManager = try #require(textView.undoManager)
        undoManager.groupsByEvent = false
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        window.orderFront(nil)
        window.makeFirstResponder(textView)
        layout()
        undoManager.removeAllActions()
    }

    deinit {
        MainActor.assumeIsolated { window.close() }
    }

    var checkboxes: [NSButton] {
        textView.subviews.compactMap { $0 as? NSButton }
            .filter { !$0.isHidden && $0.accessibilityRole() == .checkBox }
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    func event(_ action: () -> Void) {
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        action()
    }

    func click(_ button: NSButton) throws {
        let point = button.frame.center
        let content = try #require(window.contentView)
        let frameView = try #require(content.superview)
        let hit = try #require(content.hitTest(frameView.convert(textView.convert(point, to: nil), from: nil)))
        try #require(hit === button)
        let down = try mouseEvent(.leftMouseDown, at: point)
        event { hit.mouseDown(with: down) }
        layout()
    }

    func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: textView.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1
        ))
    }

    func center(of text: String) -> NSPoint {
        textView.rect(forCharacterRange: (textView.string as NSString).range(of: text)).center
    }

    func attribute(_ key: NSAttributedString.Key, at text: String) -> Any? {
        textView.textStorage?.attribute(
            key, at: (textView.string as NSString).range(of: text).location, effectiveRange: nil
        )
    }

    func layout() {
        window.contentView?.layoutSubtreeIfNeeded()
        if let manager = textView.textLayoutManager { manager.ensureLayout(for: manager.documentRange) }
        textView.needsLayout = true
        textView.layoutSubtreeIfNeeded()
    }

    func hasInk(in button: NSButton) -> Bool {
        window.displayIfNeeded()
        guard let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { return false }
        button.cacheDisplay(in: button.bounds, to: rep)
        var opaquePixels = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.05 {
                    opaquePixels += 1
                }
            }
        }
        return opaquePixels > 20
    }
}
