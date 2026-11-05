import AppKit
import Foundation
import SwiftUI
import Testing
import Vision
@testable import Notess
@testable import NotessCore
@testable import NotessEditor

@MainActor
@Suite("Task Overview presentation", .serialized, .tags(.hostedUI), .enabled(if: ProcessInfo.processInfo.environment["NOTESS_HOSTED_UI"] == "1"))
struct TaskOverviewPresentationTests {
    private static let plan = "Notes/Plán.md"
    private static let count = 60

    private func dataRows(_ table: NSTableView) -> [Int] {
        (0..<table.numberOfRows).filter { table.rowView(atRow: $0, makeIfNecessary: true)?.isGroupRowStyle != true }
    }

    private func tasksTable(_ harness: SearchPresentationHarness, rows: Int) -> NSTableView? {
        harness.tables.first { dataRows($0).count == rows }
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
        let filters = try #require(harness.tables.first { dataRows($0).count == 6 })
        harness.window.makeFirstResponder(filters)
        for _ in 0..<5 { pressArrow(harness, down: true) }
        try await harness.waitUntil { browser.filter == .completed && tasksTable(harness, rows: 1) != nil }
        for _ in 0..<5 { pressArrow(harness, down: false) }
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
        let targetRow = dataRows(returned)[50]
        #expect(visible.contains(targetRow), "visible rows \(visible) show the opened Task again")
        #expect(returned.selectedRow == targetRow, "the opened Task's row is still selected")
    }

    @Test("date groups and errors are displayed read-only; the sidebar filters and calendar notifications reclassify saved Tasks")
    func datesAndRollover() async throws {
        let fixture = try SearchPresentationFixture()
        let saved = """
            - [ ] Včerejší práce 📅 2026-11-05
            - [ ] Dnešní práce 📅 2026-11-06
            - [ ] Později 📅 2040-01-01
            - [ ] Neplatný 📅 2026-02-31
            - [x] Hotovo 📅 2026-01-01
            """
        try fixture.write(saved, to: Self.plan)
        var now = ISO8601DateFormatter().date(from: "2026-11-06T23:59:59Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let harness = try await fixture.makeHarness(now: { now }, calendar: { calendar })
        let model = harness.model
        model.sidebarMode = .tasks
        try await harness.waitUntil { tasksTable(harness, rows: 4) != nil }
        await harness.settle()
        let table = try #require(tasksTable(harness, rows: 4))
        table.scrollRowToVisible(0)
        await harness.settle()
        let surface = table.enclosingScrollView ?? table
        let labels = try renderedLabels(surface)
        let text = labels.map(\.text)
        #expect(text.contains { $0.contains(folded("Neplatný termín")) }, "rendered text: \(text)")
        #expect(text.filter { $0.contains("2026") }.count >= 2, "compact dates are drawn: \(text)")
        let headers = (0..<table.numberOfRows).filter { !dataRows(table).contains($0) }
        #expect(headers.count == 4)
        let titles = [TaskFilter.overdue, .today, .upcoming, .undated].map { folded($0.title) }
        #expect(text.filter { titles.contains($0) } == titles, "rendered group order: \(text)")

        // A click where the date is drawn can select a row, never edit a date.
        let todayRow = dataRows(table)[1]
        let rowRect = table.rect(ofRow: todayRow)
        let date = try #require(labels.first {
            $0.text.contains("2026") && rowRect.contains(table.convert($0.point, from: surface))
        })
        let windowPoint = surface.convert(date.point, to: nil)
        let visibleWindows = NSApp.windows.filter(\.isVisible).map(\.windowNumber)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: windowPoint, modifierFlags: [], timestamp: 0,
                windowNumber: harness.window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            ))
            harness.window.sendEvent(event)
        }
        await harness.settle()
        #expect(NSApp.windows.filter(\.isVisible).map(\.windowNumber) == visibleWindows)
        #expect(harness.window.sheets.isEmpty)
        #expect(harness.editor == nil)
        #expect(!model.hasUnsavedChanges)
        #expect(try String(contentsOf: fixture.rootURL.appending(path: Self.plan), encoding: .utf8) == saved)

        let filters = try #require(harness.tables.first { dataRows($0).count == 6 })
        harness.window.makeFirstResponder(filters)
        pressArrow(harness, down: true)
        try await harness.waitUntil { model.taskOverview.filter == .overdue && tasksTable(harness, rows: 1) != nil }
        pressArrow(harness, down: true)
        try await harness.waitUntil { model.taskOverview.filter == .today && tasksTable(harness, rows: 1) != nil }

        now = ISO8601DateFormatter().date(from: "2026-11-07T00:00:00Z")!
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        try await harness.waitUntil { model.taskOverview.tasks == .loaded([]) }
        #expect(model.taskOverview.filter == .today)
        now = ISO8601DateFormatter().date(from: "2026-11-06T12:00:00Z")!
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try await harness.waitUntil { tasksTable(harness, rows: 1) != nil }
        #expect(try String(contentsOf: fixture.rootURL.appending(path: Self.plan), encoding: .utf8) == saved)
    }
}

@MainActor
private func segmentedControls(in view: NSView) -> [NSSegmentedControl] {
    view.subviews.compactMap { $0 as? NSSegmentedControl } + view.subviews.flatMap(segmentedControls)
}

private func folded(_ text: String) -> String {
    text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "cs_CZ"))
}

@MainActor
private func renderedLabels(_ view: NSView) throws -> [(text: String, point: NSPoint)] {
    // SwiftUI omits its AX tree in the hosted test runner. Read actual drawn
    // labels instead of treating model state as proof that a label is visible.
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let image = try #require(bitmap.cgImage)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { observation in
        guard let text = observation.topCandidates(1).first?.string else { return nil }
        let box = observation.boundingBox
        return (
            text: folded(text),
            point: NSPoint(
                x: view.bounds.minX + box.midX * view.bounds.width,
                y: view.bounds.minY + (view.isFlipped ? 1 - box.midY : box.midY) * view.bounds.height
            )
        )
    }
}
