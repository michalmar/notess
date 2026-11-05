import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Notess
@testable import NotessCore
@testable import NotessEditor

@MainActor
@Suite("Task Overview presentation", .serialized, .tags(.hostedUI), .enabled(if: ProcessInfo.processInfo.environment["NOTESS_HOSTED_UI"] == "1"))
struct TaskOverviewPresentationTests {
    private static let plan = "Notes/Plán.md"
    private static let count = 60

    private func tasksTable(_ harness: SearchPresentationHarness, rows: Int) -> NSTableView? {
        harness.tables.first { $0.numberOfRows == rows }
    }

    private func pressArrow(_ harness: SearchPresentationHarness, down: Bool) {
        let key = down ? NSDownArrowFunctionKey : NSUpArrowFunctionKey
        let characters = String(Character(UnicodeScalar(UInt16(key))!))
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0,
            windowNumber: harness.window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: down ? 125 : 126
        )
        if let event { harness.window.sendEvent(event) }
    }

    @Test("the sidebar filters switch the list; Return on a row opens its note at the Task, writes nothing, and the list comes back at that row")
    func browseOpenAndReturn() async throws {
        let fixture = try SearchPresentationFixture()
        let lines = (1...Self.count).map { String(format: "- [ ] Úkol %02d", $0) }
        let saved = "# Plán\n\n" + lines.joined(separator: "\n") + "\n- [x] Hotový\n"
        try fixture.write(saved, to: Self.plan)
        let harness = try await fixture.makeHarness(opening: Self.plan)
        let browser = harness.model.taskOverview

        let picker = try #require(segmentedControls(in: harness.hostingView).first { $0.segmentCount == 3 })
        #expect((0..<3).map { picker.label(forSegment: $0) } == ["Journal", "Tagy", "Úkoly"])
        picker.selectedSegment = 2
        _ = picker.sendAction(picker.action, to: picker.target)
        try await harness.waitUntil { harness.model.sidebarMode == .tasks && tasksTable(harness, rows: Self.count) != nil }
        #expect(browser.filter == .open)
        #expect(harness.editor == nil, "the Task Overview replaces the editor")

        // The filter list is the sidebar's table: arrow keys move between its filters.
        let filters = try #require(harness.tables.first { $0.numberOfRows != Self.count })
        harness.window.makeFirstResponder(filters)
        pressArrow(harness, down: true)
        try await harness.waitUntil { browser.filter == .completed && tasksTable(harness, rows: 1) != nil }
        pressArrow(harness, down: false)
        try await harness.waitUntil { browser.filter == .open && tasksTable(harness, rows: Self.count) != nil }

        guard case .loaded(let tasks) = browser.tasks else { Issue.record("not loaded"); return }
        let target = tasks[50]
        #expect(target.text == "Úkol 51")
        let list = try #require(tasksTable(harness, rows: Self.count))
        harness.window.makeFirstResponder(list)
        for _ in 0...50 { pressArrow(harness, down: true) }
        await harness.settle()
        try await harness.waitUntil { browser.selectedTaskID == target.id }
        harness.pressReturn()

        try await harness.waitUntil { harness.model.sidebarMode == .journal && harness.editor != nil }
        await harness.settle()
        let editor = try #require(harness.editor)
        #expect(editor.string == saved)
        #expect(editor.selectedRange() == NSRange(location: target.boxLocation, length: 0))
        let onDisk = try String(contentsOf: fixture.rootURL.appending(path: Self.plan), encoding: .utf8)
        #expect(onDisk == saved, "browsing and opening write nothing")

        harness.model.sidebarMode = .tasks
        try await harness.waitUntil { tasksTable(harness, rows: Self.count) != nil }
        await harness.settle()
        let returned = try #require(tasksTable(harness, rows: Self.count))
        #expect(browser.filter == .open)
        #expect(browser.selectedTaskID == target.id)
        let visible = returned.rows(in: returned.visibleRect)
        #expect(visible.contains(50), "visible rows \(visible) show the opened Task again")
        #expect(returned.selectedRow == 50, "the opened Task's row is still selected")
    }

    private func showTasks(_ harness: SearchPresentationHarness, rows: Int) async throws -> NSTableView {
        harness.model.sidebarMode = .tasks
        try await harness.waitUntil { tasksTable(harness, rows: rows) != nil }
        await harness.settle()
        return try #require(tasksTable(harness, rows: rows))
    }

    @Test("rows show the source note, full heading path and enclosing Tasks; identical Tasks and same-named notes stay apart")
    func displayedContext() async throws {
        let fixture = try SearchPresentationFixture()
        try fixture.write("""
            - [ ] Úvodní úkol

            # Projekt

            ## Schůzka 👩‍💻

            - [x] Rodič hotový
              - [ ] Zavolat
            - [ ] Zavolat
            """, to: Self.plan)
        try fixture.write("# Plán\n\n- [ ] Zavolat\n", to: "Projekty/Plán.md")
        let harness = try await fixture.makeHarness(opening: nil)

        let table = try await showTasks(harness, rows: 4)

        // SwiftUI exposes no accessibility tree without an assistive client, so
        // read what each row renders from the Tasks the list shows.
        guard case .loaded(let tasks) = harness.model.taskOverview.tasks else { Issue.record("not loaded"); return }
        #expect(table.numberOfRows == tasks.count)
        #expect(tasks.map(\.accessibilityLabel) == [
            "Nesplněný úkol: Úvodní úkol, Plán — Notes",
            "Nesplněný úkol: Zavolat, v úkolu Rodič hotový, Plán — Notes · Projekt › Schůzka 👩‍💻",
            "Nesplněný úkol: Zavolat, Plán — Notes · Projekt › Schůzka 👩‍💻",
            "Nesplněný úkol: Zavolat, Plán — Projekty · Plán",
        ])
        #expect(tasks.map(\.enclosingLabel) == [nil, "Rodič hotový", nil, nil])
        #expect(Set(tasks.map(\.id)).count == tasks.count, "identical Tasks are separate rows")
    }

    @Test("a Task moved by unsaved edits opens in the editor at its actual place, scrolled into view, and the list comes back at its row")
    func opensRelocatedTask() async throws {
        let fixture = try SearchPresentationFixture()
        let lines = (1...Self.count).map { String(format: "- [ ] Úkol %02d", $0) }
        let saved = "# Plán\n\n## Seznam\n\n" + lines.joined(separator: "\n") + "\n"
        try fixture.write(saved, to: Self.plan)
        let harness = try await fixture.makeHarness(opening: Self.plan)
        let editor = try #require(harness.editor)
        let document = try #require(harness.model.document)
        // Unsaved: emoji and a decomposed accent, plus an identical Task outside
        // the target's heading, all before the target.
        let inserted = "🧑‍💻 Nový úvod, Cafe\u{301}\n- [ ] Úkol 51\n\n"
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText(inserted, replacementRange: NSRange(location: 0, length: 0))
        let dirty = inserted + saved
        #expect(document.text == dirty)

        let list = try await showTasks(harness, rows: Self.count)
        guard case .loaded(let tasks) = harness.model.taskOverview.tasks else { Issue.record("not loaded"); return }
        let target = try #require(tasks.first { $0.text == "Úkol 51" })
        #expect(target.headingPath == ["Plán", "Seznam"])
        harness.window.makeFirstResponder(list)
        for _ in 0...50 { pressArrow(harness, down: true) }
        await harness.settle()
        try await harness.waitUntil { harness.model.taskOverview.selectedTaskID == target.id }
        let row = list.selectedRow
        harness.pressReturn()

        try await harness.waitUntil { harness.model.sidebarMode == .journal && harness.editor != nil }
        await harness.settle()
        let shownEditor = try #require(harness.editor)
        #expect(shownEditor.string == dirty, "unsaved text is kept")
        #expect(document.hasUnsavedChanges)
        let line = (dirty as NSString).range(of: "- [ ] Úkol 51", options: .backwards)
        let box = NSRange(location: line.location + 2, length: 3)
        #expect(shownEditor.selectedRange() == NSRange(location: box.location, length: 0))
        #expect(harness.model.errorMessage == nil)
        let screenRect = shownEditor.firstRect(forCharacterRange: box, actualRange: nil)
        let rect = shownEditor.convert(harness.window.convertFromScreen(screenRect), from: nil)
        #expect(shownEditor.visibleRect.intersects(rect), "the Task \(rect) is in view \(shownEditor.visibleRect)")
        let onDisk = try String(contentsOf: fixture.rootURL.appending(path: Self.plan), encoding: .utf8)
        #expect(onDisk == saved, "opening writes nothing")

        let returned = try await showTasks(harness, rows: Self.count)
        #expect(harness.model.taskOverview.filter == .open)
        #expect(harness.model.taskOverview.selectedTaskID == target.id)
        #expect(returned.selectedRow == row)
        #expect(returned.rows(in: returned.visibleRect).contains(row), "the opened Task's row is in view again")
    }
}

@MainActor
private func segmentedControls(in view: NSView) -> [NSSegmentedControl] {
    view.subviews.compactMap { $0 as? NSSegmentedControl } + view.subviews.flatMap(segmentedControls)
}
