import AppKit
import NotessCore
import Testing
@testable import NotessEditor

@MainActor
@Suite("Source Due Date chips")
struct TaskDueDateChipTests {
    @Test("a valid Due Date is a chip outside the edited line and its Markdown on it, with no text or Undo change")
    func chipAndSourceTransitions() throws {
        let source = "- [ ] Poslat nabídku 📅 2026-11-06\nkonec"
        let editor = try CheckboxEditor(source)
        let marker = (source as NSString).range(of: "📅 2026-11-06")

        let chip = try #require(editor.chips.first)
        #expect(editor.chips.count == 1)
        #expect(chip.range == marker)
        #expect(chip.label == Day(year: 2026, month: 11, day: 6).dueDateLabel)
        #expect(!chip.label.contains("2026-11-06"))
        let sourceRect = editor.textView.rect(forCharacterRange: marker)
        #expect(abs(chip.frame.minX - sourceRect.minX) < 1)
        #expect(abs(chip.frame.midY - sourceRect.midY) < 1)
        #expect(editor.checkboxes.count == 1)

        let drawnChip = editor.pixels(in: chip.frame)
        editor.textView.setSelectedRange(NSRange(location: marker.location + 3, length: 0))
        editor.layout()
        #expect(editor.chips.isEmpty, "entering the line shows the Markdown date")
        #expect(editor.pixels(in: chip.frame) != drawnChip)
        #expect(editor.checkboxes.count == 1, "the Task marker stays a checkbox while the date is edited")

        editor.textView.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        editor.layout()
        #expect(editor.chips.map(\.range) == [marker])
        #expect(editor.pixels(in: chip.frame) == drawnChip)
        #expect(editor.textView.string == source)
        #expect(!editor.undoManager.canUndo)
    }

    @Test("typing, changing and deleting a date next to emoji, decomposed text and links is ordinary undoable editing")
    func typedEdits() throws {
        let task = "- [ ] 🧑‍💻 Cafe\u{301} [[Plán]] [web](https://x.cz)"
        let source = "\(task)\nkonec"
        let editor = try CheckboxEditor(source)
        var changes = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: editor.textView, queue: nil
        ) { _ in MainActor.assumeIsolated { changes += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }
        let end = (task as NSString).length
        // The last line, which is not the Task's.
        var away: NSRange { NSRange(location: (editor.textView.string as NSString).length, length: 0) }
        #expect(editor.chips.isEmpty)

        editor.textView.setSelectedRange(NSRange(location: end, length: 0))
        for character in [" ", "📅", " ", "2026", "-11", "-06"] {
            editor.event { editor.textView.insertText(character, replacementRange: editor.textView.selectedRange()) }
            editor.layout()
            #expect(editor.chips.isEmpty, "the edited line shows its Markdown")
        }
        let dated = "\(task) 📅 2026-11-06\nkonec"
        #expect(editor.textView.string == dated)
        let caret = editor.textView.selectedRange()
        #expect(caret == NSRange(location: (dated as NSString).range(of: "\n").location, length: 0))
        #expect(editor.checkboxes.count == 1)

        editor.textView.setSelectedRange(away)
        editor.layout()
        let marker = (dated as NSString).range(of: "📅 2026-11-06")
        #expect(editor.chips.map(\.range) == [marker])
        #expect(editor.chips.first?.label == Day(year: 2026, month: 11, day: 6).dueDateLabel)
        let link = editor.textView.rect(forCharacterRange: (dated as NSString).range(of: "[web](https://x.cz)"))
        #expect(editor.chips.allSatisfy { !$0.frame.intersects(link) }, "the chip covers only its date")

        // Changing the date: select the day inside the Markdown and retype it.
        let day = NSRange(location: marker.upperBound - 2, length: 2)
        editor.textView.setSelectedRange(day)
        editor.layout()
        #expect(editor.chips.isEmpty)
        #expect(editor.textView.selectedRange() == day, "showing the Markdown keeps the selection")
        editor.event { editor.textView.insertText("24", replacementRange: day) }
        editor.textView.setSelectedRange(away)
        editor.layout()
        #expect(editor.chips.first?.label == Day(year: 2026, month: 11, day: 24).dueDateLabel)

        // Removing it.
        let removal = NSRange(location: marker.location - 1, length: marker.length + 1)
        editor.textView.setSelectedRange(removal)
        editor.event { editor.textView.insertText("", replacementRange: removal) }
        editor.textView.setSelectedRange(away)
        editor.layout()
        #expect(editor.textView.string == source)
        #expect(editor.chips.isEmpty)
        let edits = changes

        editor.undoManager.undo()
        editor.textView.setSelectedRange(away)
        editor.layout()
        #expect(editor.textView.string == "\(task) 📅 2026-11-24\nkonec")
        #expect(editor.chips.first?.label == Day(year: 2026, month: 11, day: 24).dueDateLabel)
        editor.undoManager.undo()
        editor.textView.setSelectedRange(away)
        editor.layout()
        #expect(editor.textView.string == dated)
        #expect(editor.chips.first?.label == Day(year: 2026, month: 11, day: 6).dueDateLabel)
        editor.undoManager.redo()
        editor.undoManager.redo()
        editor.textView.setSelectedRange(away)
        editor.layout()
        #expect(editor.textView.string == source)
        #expect(editor.chips.isEmpty)
        #expect(changes == edits + 4, "only the Undo and Redo edits report changes")
        #expect(!editor.undoManager.canRedo)
    }

    @Test("impossible, conflicting, incomplete and code dates stay unchanged source text without chips")
    func invalidInput() throws {
        let source = """
            - [ ] nemožné 📅 2026-02-31
            - [ ] sporné 📅 2026-11-06 📅 2026-11-07
            - [ ] rozepsané 📅 2026-11-
            - [ ] prázdné 📅
            - [ ] kód `📅 2026-11-06`
            text 📅 2026-11-06
            - [ ] přestupný 📅 2028-02-29 a znovu 📅 2028-02-29
            konec
            """
        let editor = try CheckboxEditor(source)
        let string = source as NSString
        #expect(editor.chips.map(\.range) == [
            string.range(of: "📅 2028-02-29"),
            string.range(of: "📅 2028-02-29", options: .backwards),
        ], "only the valid, consistent Task date gets chips")
        #expect(editor.checkboxes.count == 6)

        // Completing an impossible date turns it into a chip only once the line is left.
        let impossible = string.range(of: "2026-02-31")
        editor.textView.setSelectedRange(NSRange(location: impossible.location + 8, length: 2))
        editor.event { editor.textView.insertText("28", replacementRange: editor.textView.selectedRange()) }
        editor.layout()
        #expect(editor.chips.count == 2)
        editor.textView.setSelectedRange(NSRange(location: string.length, length: 0))
        editor.layout()
        #expect(editor.chips.first?.range == (editor.textView.string as NSString).range(of: "📅 2026-02-28"))
        #expect(editor.textView.string == source.replacingOccurrences(of: "2026-02-31", with: "2026-02-28"))
    }

    @Test("caret movement, focus and style changes keep a real note clean, and a date edit is written only on save")
    func explicitSave() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "NotessDueDate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "2026-11-05.md")
        let source = "# Den\n\n- [ ] zavolat 📅 2026-11-06\n"
        let edited = "# Den\n\n- [ ] zavolat 📅 2026-11-09\n"
        try Data(source.utf8).write(to: url)
        let note = try NoteDocument.open(fileURL: url, newFileContent: "")
        let editor = try CheckboxEditor(note.text)
        let coordinator = MarkdownEditor.Coordinator()
        coordinator.onTextChange = { note.text = $0 }
        editor.textView.delegate = coordinator
        var changes = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: editor.textView, queue: nil
        ) { _ in MainActor.assumeIsolated { changes += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }
        let marker = (source as NSString).range(of: "📅 2026-11-06")

        for location in [0, marker.location + 4, 10, marker.upperBound, (source as NSString).length] {
            editor.textView.setSelectedRange(NSRange(location: location, length: 0))
            editor.layout()
        }
        editor.textView.setSelectedRange(NSRange(location: marker.location + 3, length: 0))
        editor.layout()
        #expect(editor.chips.isEmpty)
        editor.window.makeFirstResponder(nil)
        editor.layout()
        #expect(editor.chips.map(\.range) == [marker], "leaving the editor restores the chip")
        #expect(editor.textView.selectedRange() == NSRange(location: marker.location + 3, length: 0))
        editor.window.makeFirstResponder(editor.textView)
        editor.layout()
        #expect(editor.chips.isEmpty, "focusing the editor again shows the caret line's Markdown")
        editor.textView.markdownStyle = MarkdownEditorStyle(fontName: "System", fontSize: 20)
        editor.layout()
        #expect(note.text == source)
        #expect(!note.hasUnsavedChanges)
        #expect(!editor.undoManager.canUndo)
        #expect(changes == 0)
        #expect(try String(contentsOf: url, encoding: .utf8) == source)

        let day = NSRange(location: marker.upperBound - 1, length: 1)
        editor.event { editor.textView.insertText("9", replacementRange: day) }
        #expect(note.text == edited)
        #expect(note.hasUnsavedChanges)
        #expect(try String(contentsOf: url, encoding: .utf8) == source)
        editor.undoManager.undo()
        #expect(note.text == source)
        #expect(!note.hasUnsavedChanges)
        editor.undoManager.redo()
        try note.save()
        #expect(try String(contentsOf: url, encoding: .utf8) == edited)
        #expect(!note.hasUnsavedChanges)
    }

    @Test("clicking a chip only puts the caret into its date; completed Tasks keep their style; read-only views get no chips")
    func clickCompletedAndReadOnly() throws {
        let source = "- [x] hotovo 📅 2026-11-06\n- [ ] otevřené 📅 2026-12-01\nkonec"
        let editor = try CheckboxEditor(source)
        let string = source as NSString
        #expect(editor.chips.count == 2)
        #expect(editor.attribute(.strikethroughStyle, at: "hotovo") as? Int == NSUnderlineStyle.single.rawValue)
        #expect(editor.checkboxes.map(\.state) == [.on, .off])
        let windows = NSApp.windows.filter(\.isVisible).count

        let chip = try #require(editor.chips.last)
        let content = try #require(editor.window.contentView)
        let frameView = try #require(content.superview)
        let hit = try #require(content.hitTest(frameView.convert(editor.textView.convert(chip.frame.center, to: nil), from: nil)))
        #expect(hit !== editor.textView && hit.isDescendant(of: editor.textView))
        #expect(hit.accessibilityRole() == nil || hit.isAccessibilityElement() == false)
        #expect(!editor.textView.pointingHandTarget(containing: chip.frame.center))
        // A plain click on the text view places the caret, as on any other text.
        let index = editor.textView.characterIndexForInsertion(at: chip.frame.center)
        #expect(NSLocationInRange(index, chip.range) || index == chip.range.upperBound)
        editor.textView.setSelectedRange(NSRange(location: index, length: 0))
        editor.layout()
        #expect(editor.chips.map(\.range) == [string.range(of: "📅 2026-11-06")])
        #expect(NSApp.windows.filter(\.isVisible).count == windows)
        #expect(editor.textView.string == source)
        #expect(!editor.undoManager.canUndo)

        editor.textView.isEditable = false
        editor.layout()
        #expect(editor.chips.isEmpty)
        #expect(editor.checkboxes.allSatisfy { !$0.isEnabled })
        #expect(editor.textView.string == source)
    }

    @Test("chips follow their dates through wrapping, resizing and scrolling with no stale chips", arguments: [7.5, 15.0, 30.0])
    func wrappingAndScrolling(size: Double) throws {
        let line = "- [ ] 🧠 žluťoučký kůň " + String(repeating: "dlouhý text ", count: 5) + "📅 2026-11-06 a dál"
        let source = (0..<40).map { "\(line) \($0)" }.joined(separator: "\n") + "\nkonec"
        let editor = try CheckboxEditor(source, width: 300)
        editor.textView.markdownStyle = MarkdownEditorStyle(fontName: "System", fontSize: size)
        editor.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        editor.layout()
        let string = source as NSString
        func check() {
            let chips = editor.chips
            if size < 30 { #expect(!chips.isEmpty) }
            #expect(chips.count < 40)
            for chip in chips {
                #expect(string.substring(with: chip.range) == "📅 2026-11-06")
                #expect(chip.frame.intersects(editor.textView.visibleRect))
            }
            // Every date in view is a chip exactly over it, unless the date wraps.
            let viewport = editor.textView.viewportCharacterRange() ?? NSRange()
            var search = NSRange(location: 0, length: string.length)
            while case let marker = string.range(of: "📅 2026-11-06", range: search), marker.location != NSNotFound {
                search = NSRange(location: marker.upperBound, length: string.length - marker.upperBound)
                let frames = editor.textView.segmentFrames(of: marker)
                guard NSLocationInRange(marker.location, viewport),
                      frames.contains(where: { $0.intersects(editor.textView.visibleRect) }) else { continue }
                let chip = chips.first { $0.range == marker }
                if frames.count == 1 {
                    #expect(chip.map { abs($0.frame.minX - frames[0].minX) < 1 && abs($0.frame.minY - frames[0].minY) < 1 } == true)
                } else {
                    #expect(chip == nil, "a wrapped date stays source text")
                }
            }
        }
        check()
        let top = editor.chips.map(\.range)

        editor.window.setContentSize(NSSize(width: 460, height: 300))
        editor.layout()
        check()

        let last = string.range(of: " 39", options: .backwards)
        editor.textView.scrollRangeToVisible(last)
        editor.layout()
        check()
        #expect(Set(editor.chips.map(\.range)).isDisjoint(with: top), "chips scrolled away are gone")
        #expect(editor.textView.string == source)
        #expect(!editor.undoManager.canUndo)
        #expect(editor.textView.textLayoutManager != nil)
    }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}

extension CheckboxEditor {
    var chips: [TaskDueDateChips.Chip] { textView.taskDueDateChips.visibleChips }

    /// What the window draws in `rect` of the text view, chips included.
    func pixels(in rect: NSRect) -> Data {
        window.displayIfNeeded()
        guard let rep = textView.bitmapImageRepForCachingDisplay(in: rect) else { return Data() }
        textView.cacheDisplay(in: rect, to: rep)
        return rep.tiffRepresentation ?? Data()
    }
}
