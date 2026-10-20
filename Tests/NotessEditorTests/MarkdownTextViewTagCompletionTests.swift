import AppKit
import NotessCore
import Testing
@testable import NotessEditor

@MainActor
@Suite("Completing Tags with Tab")
struct MarkdownTextViewTagCompletionTests {
    private let window: NSWindow
    private let textView: MarkdownTextView
    private let undoManager: UndoManager
    private let vault = FakeTagVocabulary(tags: ["acme", "akce", "Acme-2026", "projekt", "škola", "školka", "2026-plan"])

    init() throws {
        let scrollView = MarkdownTextViewFactory.makeScrollView(style: .standard)
        textView = scrollView.documentView as! MarkdownTextView
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        scrollView.frame = window.contentLayoutRect
        undoManager = try #require(textView.undoManager)
        undoManager.groupsByEvent = false
        textView.tagSuggestionSource = vault.source()
    }

    // MARK: Helpers

    /// Sets the text with the caret at `‸`.
    private func load(_ text: String) {
        textView.string = text.replacingOccurrences(of: "‸", with: "")
        textView.setSelectedRange(NSRange(location: (text as NSString).range(of: "‸").location, length: 0))
    }

    /// The text with `‸` at the caret, or `[`…`]` around the selection.
    private var marked: String {
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
    private func event(_ action: () -> Void) {
        undoManager.beginUndoGrouping()
        action()
        undoManager.endUndoGrouping()
    }

    private func type(_ text: String) {
        for character in text {
            event { textView.insertText(String(character), replacementRange: textView.selectedRange()) }
        }
    }

    private func command(_ selector: Selector) {
        event { textView.doCommand(by: selector) }
    }

    private var rows: [String] { textView.visibleTagSuggestions }
    private var selected: String? { textView.selectedTagSuggestion }

    // MARK: Type, filter, Tab, undo

    @Test("typing a prefix shows matching saved Tags; narrowing, broadening and Tab complete it as one undoable edit")
    func typeFilterTabUndo() async {
        load("Porada ‸ dnes")
        type("#")
        await settle()
        #expect(rows.isEmpty)
        #expect(vault.requests.isEmpty)

        type("a")
        await settle()
        #expect(rows == ["#acme", "#acme-2026", "#akce"])
        #expect(selected == "#acme")

        type("c")
        await settle()
        #expect(rows == ["#acme", "#acme-2026"])

        command(#selector(NSTextView.deleteBackward(_:)))
        await settle()
        #expect(rows == ["#acme", "#acme-2026", "#akce"])
        type("k")
        await settle()
        #expect(rows == ["#akce"])

        var changes = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: textView, queue: nil
        ) { _ in MainActor.assumeIsolated { changes += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }

        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "Porada #akce‸ dnes")
        #expect(rows.isEmpty)
        #expect(changes == 1)
        #expect(undoManager.undoActionName == "Doplnit štítek")
        await settle()
        #expect(rows.isEmpty)

        // Typing continues normally after the completed Tag.
        type(",")
        #expect(marked == "Porada #akce,‸ dnes")

        undoManager.undo()
        #expect(marked == "Porada #akce‸ dnes")
        undoManager.undo()
        #expect(textView.string == "Porada #ak dnes")
        await settle()
        #expect(rows.isEmpty)
        undoManager.redo()
        #expect(textView.string == "Porada #akce dnes")
        #expect(changes >= 3)
    }

    @Test("an exact match is left out while longer matches stay; no match shows nothing and Tab is a tab")
    func exactAndNoMatch() async {
        load("‸")
        type("#acme")
        await settle()
        #expect(rows == ["#acme-2026"])

        type("-2026")
        await settle()
        #expect(rows.isEmpty)

        load("x ‸")
        type("#zz")
        await settle()
        #expect(rows.isEmpty)
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "x #zz\t‸")
    }

    @Test("digit, hyphen and underscore prefixes complete saved Tags")
    func letterlessPrefix() async {
        load("‸")
        type("#2")
        await settle()
        #expect(rows == ["#2026-plan"])
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "#2026-plan‸")
    }

    @Test("completing in the middle of a Tag replaces the whole Tag, keeping the text around it")
    func midToken() async {
        load("Úkol (#pr‸jekt), hotovo")
        type("o")
        await settle()
        #expect(rows == ["#projekt"])
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "Úkol (#projekt‸), hotovo")
    }

    @Test("Unicode before and inside a Tag is replaced safely, decomposed letters included")
    func unicode() async {
        load("😀 Příliš #S\u{30C}‸ola, dál")
        type("k")
        await settle()
        #expect(rows == ["#škola", "#školka"])
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "😀 Příliš #škola‸, dál")
    }

    @Test("a Tag typed in a heading, list or quote is completed")
    func blockContexts() async {
        for (prefix, expected) in [("## Porada ", "## Porada #acme‸"), ("- ", "- #acme‸"), ("> ", "> #acme‸")] {
            load(prefix + "‸")
            type("#ac")
            await settle()
            #expect(rows == ["#acme", "#acme-2026"])
            command(#selector(NSResponder.insertTab(_:)))
            #expect(marked == expected)
        }
    }

    @Test("no completion where Tags are not recognised")
    func excludedContexts() async {
        for text in ["`‸`", "C‸", "[[‸]]", "https://example.com/‸", "\\‸"] {
            load(text)
            type("#ac")
            await settle()
            #expect(rows.isEmpty, "\(text)")
        }
    }

    // MARK: Dismissal

    @Test("Escape closes the list without editing; a later edit reopens it")
    func escape() async {
        load("‸")
        type("#a")
        await settle()
        #expect(!rows.isEmpty)
        command(#selector(NSResponder.cancelOperation(_:)))
        #expect(rows.isEmpty)
        #expect(marked == "#a‸")
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "#a\t‸")

        command(#selector(NSTextView.deleteBackward(_:)))
        await settle()
        #expect(rows == ["#acme", "#acme-2026", "#akce"])
    }

    @Test("moving the caret, selecting, losing focus or loading another note closes the list")
    func dismissals() async {
        load("‸")
        type("#a")
        await settle()
        command(#selector(NSResponder.moveLeft(_:)))
        #expect(rows.isEmpty)

        load("x ‸")
        type("#a")
        await settle()
        command(#selector(NSResponder.moveLeftAndModifySelection(_:)))
        #expect(rows.isEmpty)

        window.makeFirstResponder(textView)
        load("y ‸")
        type("#a")
        await settle()
        #expect(!rows.isEmpty)
        window.makeFirstResponder(nil)
        #expect(rows.isEmpty)

        load("z ‸")
        type("#a")
        await settle()
        load("Jiná poznámka ‸")
        #expect(rows.isEmpty)
    }

    @Test("moving into an existing Tag does not open completion")
    func navigationDoesNotOpen() async {
        load("#acm‸ text")
        command(#selector(NSResponder.moveLeft(_:)))
        command(#selector(NSResponder.moveRight(_:)))
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        await settle()
        #expect(rows.isEmpty)
        #expect(vault.requests.isEmpty)
    }

    @Test("Return and Shift-Tab close the list and keep their usual behaviour")
    func returnAndBacktab() async {
        load("‸")
        type("#a")
        await settle()
        command(#selector(NSResponder.insertNewline(_:)))
        #expect(marked == "#a\n‸")
        #expect(rows.isEmpty)

        load("| x | #a‸ |\n| - | - |")
        type("c")
        await settle()
        #expect(!rows.isEmpty)
        command(#selector(NSResponder.insertBacktab(_:)))
        #expect(marked == "| [x] | #ac |\n| - | - |")
        #expect(rows.isEmpty)
    }

    @Test("a read-only view never opens completion")
    func readOnly() async {
        load("‸")
        type("#a")
        await settle()
        #expect(!rows.isEmpty)
        textView.isEditable = false
        #expect(rows.isEmpty)

        load("#a‸")
        type("c")
        command(#selector(NSResponder.insertTab(_:)))
        await settle()
        #expect(rows.isEmpty)
        #expect(textView.string == "#a")
    }

    // MARK: Tables

    @Test("in a table Tab completes first and the next Tab moves to the next cell")
    func tables() async {
        load("| #a‸ | b |\n| - | - |\n| c | d |")
        type("k")
        await settle()
        #expect(rows == ["#akce"])
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "| #akce‸ | b |\n| - | - |\n| c | d |")
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "| #akce | [b] |\n| - | - |\n| c | d |")
    }

    @Test("in a table Tab navigates when nothing matches or the lookup is pending")
    func tablesWithoutSuggestion() async {
        load("| #z‸ | b |\n| - | - |")
        type("z")
        await settle()
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "| #zz | [b] |\n| - | - |")

        vault.isSuspended = true
        load("| #a‸ | b |\n| - | - |")
        type("c")
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "| #ac | [b] |\n| - | - |")
        vault.resumeAll()
        await settle()
        #expect(rows.isEmpty)
        #expect(textView.string == "| #ac | b |\n| - | - |")
    }

    // MARK: Asynchronous lookups

    @Test("typing and Tab do not wait for a pending lookup")
    func pendingLookup() async {
        vault.isSuspended = true
        load("‸")
        type("#a")
        #expect(rows.isEmpty)
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "#a\t‸")
        vault.resumeAll()
        await settle()
        #expect(rows.isEmpty)
    }

    @Test("out-of-order responses: only the current prefix's result is shown")
    func outOfOrder() async {
        vault.isSuspended = true
        load("‸")
        type("#a")
        await settle()
        type("k")
        await settle()
        #expect(vault.pendingPrefixes == ["a", "ak"])

        vault.resume("ak")
        await settle()
        #expect(rows == ["#akce"])
        vault.resume("a")
        await settle()
        #expect(rows == ["#akce"])

        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "#akce‸")
    }

    @Test("a late response after Escape, acceptance, another note or another Vault changes nothing")
    func lateResponses() async {
        // Escape while a refresh is pending.
        load("‸")
        type("#a")
        await settle()
        vault.isSuspended = true
        type("c")
        #expect(rows == ["#acme", "#acme-2026"])
        #expect(selected == nil)
        command(#selector(NSResponder.cancelOperation(_:)))
        vault.resumeAll()
        await settle()
        #expect(rows.isEmpty)
        #expect(marked == "#ac‸")

        // Tab while a refresh is pending keeps its usual meaning.
        vault.isSuspended = false
        load("‸")
        type("#a")
        await settle()
        vault.isSuspended = true
        type("k")
        #expect(rows == ["#akce"])
        #expect(selected == nil)
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "#ak\t‸")
        vault.resumeAll()
        await settle()
        #expect(rows.isEmpty)
        #expect(marked == "#ak\t‸")

        // Acceptance, then a late response.
        vault.isSuspended = false
        load("‸")
        type("#ak")
        await settle()
        vault.isSuspended = true
        type("c")
        await settle()
        vault.resumeAll()
        await settle()
        #expect(selected == "#akce")
        vault.isSuspended = true
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "#akce‸")
        vault.resumeAll()
        await settle()
        #expect(rows.isEmpty)
        #expect(marked == "#akce‸")

        // Another note.
        load("‸")
        type("#a")
        load("Jiná ‸")
        vault.resumeAll()
        await settle()
        #expect(rows.isEmpty)

        // Another Vault.
        load("‸")
        type("#a")
        textView.tagSuggestionSource = vault.source(id: "other vault")
        vault.resumeAll()
        await settle()
        #expect(rows.isEmpty)
        #expect(marked == "#a‸")
    }

    @Test("a failed lookup is reported once, shows nothing and leaves Tab alone")
    func failure() async {
        var failures = 0
        textView.onTagSuggestionFailure = { _ in failures += 1 }
        vault.failure = FakeTagVocabulary.Failure()
        load("‸")
        type("#a")
        await settle()
        #expect(rows.isEmpty)
        #expect(failures == 1)
        type("c")
        await settle()
        #expect(failures == 1)
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "#ac\t‸")

        vault.failure = nil
        load("‸")
        type("#a")
        await settle()
        #expect(rows.count == 3)
    }

    /// Lets queued lookups and their main-actor continuations run.
    private func settle() async {
        for _ in 0..<5 {
            await Task.yield()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

/// Saved Tags served like the Search Index would, optionally holding each
/// lookup until the test resumes it.
@MainActor
final class FakeTagVocabulary {
    struct Failure: Error {}

    var tags: [String]
    var isSuspended = false
    var failure: Error?
    private(set) var requests: [String] = []
    private var pending: [(prefix: String, continuation: CheckedContinuation<[String], Error>)] = []

    init(tags: [String]) {
        self.tags = tags
    }

    var pendingPrefixes: [String] { pending.map(\.prefix) }

    func source(id: AnyHashable = "vault") -> TagSuggestionSource {
        TagSuggestionSource(id: id) { [unowned self] prefix in
            try await self.lookup(prefix)
        }
    }

    private func lookup(_ prefix: String) async throws -> [String] {
        requests.append(prefix)
        if isSuspended {
            return try await withCheckedThrowingContinuation { continuation in
                pending.append((prefix, continuation))
            }
        }
        if let failure { throw failure }
        return tags.filter { Tag.normalize($0).hasPrefix(Tag.normalize(prefix)) }
    }

    func resume(_ prefix: String) {
        guard let index = pending.firstIndex(where: { $0.prefix == prefix }) else { return }
        let request = pending.remove(at: index)
        request.continuation.resume(returning: tags)
    }

    func resumeAll() {
        let requests = pending
        pending.removeAll()
        for request in requests { request.continuation.resume(returning: tags) }
    }
}
