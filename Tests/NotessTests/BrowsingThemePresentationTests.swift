import AppKit
import SwiftUI
import Testing
@testable import Notess
@testable import NotessCore
@testable import NotessEditor

/// Theme selection while finding notes and browsing Tags and Tasks: global
/// search, the Tag Timeline and the Task Overview. Shares the hosted-window
/// approach and colour helpers of `ThemePresentationTests`.
@MainActor
@Suite("Theme presentation of search, Tags and Tasks", .serialized, .tags(.hostedUI), .enabled(if: ProcessInfo.processInfo.environment["NOTESS_HOSTED_UI"] == "1"))
struct BrowsingThemePresentationTests {
    @Test("an open global search recolours from Settings without losing its query, scope, selection or scroll")
    func globalSearch() async throws {
        let fixture = try SearchPresentationFixture()
        try fixture.write("# Alfa\n\n## Kickoff\nKickoff s klientem\n", to: "Notes/Alfa.md")
        for index in 1...12 {
            try fixture.write("# Beta \(index)\n\n## Porada\nPorada o kickoff plánu \(index)\n", to: "Notes/Beta \(index).md")
        }
        try fixture.write("## Den\nkickoff ráno\n", to: "Journal/2026/03/2026-03-14.md")
        let harness = try await fixture.makeHarness(opening: "Notes/Alfa.md")
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        let settingsWindow = makeSettingsWindow(model: harness.model)
        defer { settingsWindow.close() }
        await harness.settle()
        let picker = try themePicker(in: settingsWindow)
        harness.window.makeKeyAndOrderFront(nil)
        await harness.settle()

        let tablesBeforeSearch = Set(harness.tables.map(ObjectIdentifier.init))
        harness.model.presentSearch()
        await harness.settle()
        harness.type("kickoff")
        let search = try #require(harness.model.globalSearch)
        try await harness.waitUntil { search.results.count == 14 && !search.isSearching }
        search.scope = .notes
        try await harness.waitUntil { search.results.count == 13 && !search.isSearching }
        let selected = search.results[1].id
        search.selection = selected
        await harness.settle()
        let list = try #require(harness.tables.first { !tablesBeforeSearch.contains(ObjectIdentifier($0)) })
        let scroll = try #require(list.enclosingScrollView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 40))
        scroll.reflectScrolledClipView(scroll.contentView)
        await harness.settle()
        let viewport = list.visibleRect
        #expect(viewport.minY > 0)

        for theme in ["Noir Essence", "Dark", "Light", "Podle systému", "Noir Essence"] {
            try select(theme, in: picker)
            harness.window.makeKeyAndOrderFront(nil)
            await harness.settle()

            #expect(harness.model.globalSearch === search, "\(theme) keeps the open search")
            #expect(search.query == "kickoff" && search.scope == .notes && search.selection == selected)
            #expect(harness.tables.contains { $0 === list }, "the result list stays mounted")
            #expect(abs(list.visibleRect.minY - viewport.minY) <= 1, "\(theme) keeps the result list's scroll")
            #expect(!harness.model.hasUnsavedChanges)

            let colors = try searchColors(harness, list: list, selectedRow: list.selectedRow)
            switch theme {
            case "Noir Essence":
                try expectNoirEssenceSearch(colors)
            default:
                // Native rendering as it was before themes existed.
                let isDark = list.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let (panel, results, header) = isDark ? (0.183, 0.157, 0.178) : (0.956, 1.0, 0.931)
                #expect(colorDistance(colors.panel, NSColor(white: panel, alpha: 1)) < 0.01, "\(theme) keeps the native panel: \(colors.panel)")
                #expect(colorDistance(colors.listBackground, NSColor(white: results, alpha: 1)) < 0.01,
                        "\(theme) keeps the native results background: \(colors.listBackground)")
                #expect(colorDistance(colors.header, NSColor(white: header, alpha: 1)) < 0.01, "\(theme) keeps native group headers: \(colors.header)")
                #expect(colors.highlightPixels.orange == 0, "\(theme) highlights matches with the system accent")
            }
        }

        harness.model.isSearchPresented = false
        await harness.settle()
        harness.model.presentSearch()
        await harness.settle()
        harness.type("kickoff")
        let reopened = try #require(harness.model.globalSearch)
        try await harness.waitUntil { reopened.results.count == 14 && !reopened.isSearching }
        await harness.settle()
        let newList = try #require(harness.tables.first { !tablesBeforeSearch.contains(ObjectIdentifier($0)) })
        try expectNoirEssenceSearch(try searchColors(harness, list: newList, selectedRow: newList.selectedRow))

        try select("Podle systému", in: picker)
        await harness.settle()
    }

    @Test("the open Tag Timeline and its read-only Markdown recolour without losing the selected Tag or scroll, and without restyling")
    func tagTimeline() async throws {
        let fixture = try SearchPresentationFixture()
        try fixture.write("# Alfa\n\nA Free Note.\n", to: "Notes/Alfa.md")
        for day in 1...14 {
            let date = String(format: "2026-03-%02d", day)
            try fixture.write(
                "## Porada \(day)\nBody text #projekt with [site](https://example.com) and [[Alfa]].\n\n> A quotation\n\n- [x] Done task\n",
                to: "Journal/2026/03/\(date).md"
            )
        }
        let harness = try await fixture.makeHarness(opening: "Notes/Alfa.md")
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        let settingsWindow = makeSettingsWindow(model: harness.model)
        defer { settingsWindow.close() }
        await harness.settle()
        let picker = try themePicker(in: settingsWindow)
        harness.window.makeKeyAndOrderFront(nil)

        harness.model.openTagTimeline("projekt")
        try await harness.waitUntil {
            guard case .loaded(let days) = harness.model.tagTimeline.timeline else { return false }
            return days.count == 14 && readOnlyViews(harness).count >= 2
        }
        await harness.settle()
        let browser = harness.model.tagTimeline
        let scroll = try #require(readOnlyViews(harness).first?.enclosingScrollView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
        scroll.reflectScrolledClipView(scroll.contentView)
        await harness.settle()
        let origin = scroll.contentView.bounds.origin
        #expect(origin.y > 0)
        let shown = try #require(visibleReadOnlyView(harness, in: scroll))
        let storage = try #require(shown.textStorage)
        let formatted = NSAttributedString(attributedString: storage)

        for theme in ["Noir Essence", "Dark", "Light", "Podle systému", "Noir Essence"] {
            try select(theme, in: picker)
            harness.window.makeKeyAndOrderFront(nil)
            await harness.settle()

            #expect(harness.model.sidebarMode == .tags && browser.selectedTag == "projekt", "\(theme) keeps the selected Tag")
            #expect(scroll.contentView.bounds.origin == origin, "\(theme) keeps the timeline's scroll")
            #expect(readOnlyViews(harness).contains { $0 === shown }, "the read-only Markdown stays mounted")
            #expect(storage.isEqual(to: formatted), "\(theme) only redraws the read-only Markdown")
            #expect(!harness.model.hasUnsavedChanges)
            let colors = try timelineColors(harness, card: shown)
            switch theme {
            case "Noir Essence":
                try expectNoirEssenceTimeline(colors, in: shown)
            case "Dark":
                #expect(colors.detail.luminance < 0.3, "dark timeline: \(colors.detail)")
                #expect(srgb(colors.text, in: shown.effectiveAppearance).luminance > 0.7, "light text on dark")
            default:
                #expect(!isCream(colors.detail) && !isCream(colors.card), "\(theme) is native: \(colors.detail)")
                #expect(colorDistance(srgb(colors.text, in: shown.effectiveAppearance), srgb(.textColor, in: shown.effectiveAppearance)) < 0.01,
                        "\(theme) read-only text is native")
                #expect(colors.blue > 20, "\(theme) keeps the native link colour")
            }
        }

        harness.model.sidebarMode = .journal
        await harness.settle()
        harness.model.openTagTimeline("projekt")
        try await harness.waitUntil { readOnlyViews(harness).count >= 2 }
        await harness.settle()
        let reopened = try #require(readOnlyViews(harness).first)
        try expectNoirEssenceTimeline(try timelineColors(harness, card: reopened), in: reopened)

        try select("Podle systému", in: picker)
        await harness.settle()
    }

    @Test("the open Task Overview recolours without losing its filter, selected Task or scroll")
    func taskOverview() async throws {
        let fixture = try SearchPresentationFixture()
        let overdue = (1...30).map { String(format: "- [ ] Úkol %02d 📅 2026-11-01", $0) }
        let saved = "# Plán\n\n" + overdue.joined(separator: "\n") + "\n- [ ] Dnešní 📅 2026-11-06\n- [ ] Bez termínu\n"
        try fixture.write(saved, to: "Notes/Plán.md")
        let now = ISO8601DateFormatter().date(from: "2026-11-06T12:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let harness = try await fixture.makeHarness(now: { now }, calendar: { calendar })
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        let settingsWindow = makeSettingsWindow(model: harness.model)
        defer { settingsWindow.close() }
        await harness.settle()
        let picker = try themePicker(in: settingsWindow)
        harness.window.makeKeyAndOrderFront(nil)

        let browser = harness.model.taskOverview
        harness.model.sidebarMode = .tasks
        try await harness.waitUntil { taskTable(harness, rows: 32) != nil }
        await harness.settle()
        let table = try #require(taskTable(harness, rows: 32))
        harness.window.makeFirstResponder(table)
        for _ in 0..<20 { pressDown(harness) }
        await harness.settle()
        guard case .loaded(let tasks) = browser.tasks else { Issue.record("not loaded"); return }
        let target = try #require(tasks.first { $0.text.hasPrefix("Úkol 20") })
        try await harness.waitUntil { browser.selectedTaskID == target.id }
        let scroll = try #require(table.enclosingScrollView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: table.selectedRow).minY - 120))
        scroll.reflectScrolledClipView(scroll.contentView)
        await harness.settle()
        let viewport = table.visibleRect
        #expect(viewport.minY > 0)

        for theme in ["Noir Essence", "Dark", "Light", "Podle systému", "Noir Essence"] {
            try select(theme, in: picker)
            harness.window.makeKeyAndOrderFront(nil)
            harness.window.makeFirstResponder(table)
            await harness.settle()

            #expect(harness.model.sidebarMode == .tasks && browser.filter == .open, "\(theme) keeps the filter")
            #expect(browser.selectedTaskID == target.id, "\(theme) keeps the selected Task")
            #expect(harness.tables.contains { $0 === table }, "the Task list stays mounted")
            #expect(abs(table.visibleRect.minY - viewport.minY) <= 1, "\(theme) keeps the Task list's scroll")
            #expect(try String(contentsOf: fixture.rootURL.appending(path: "Notes/Plán.md"), encoding: .utf8) == saved)

            let colors = try taskColors(harness, table: table)
            switch theme {
            case "Noir Essence":
                expectNoirEssenceTasks(colors)
            default:
                // The native list background as it rendered before themes existed.
                let isDark = table.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let native = NSColor(white: isDark ? 0.157 : 1, alpha: 1)
                #expect(colorDistance(colors.list, native) < 0.01, "\(theme) keeps the native list background: \(colors.list)")
                #expect(colors.blue > 20, "\(theme) keeps the native link colour")
                let overdue = try #require(colors.overdue)
                #expect(colorDistance(overdue, srgb(.systemRed, in: table.effectiveAppearance)) < colorDistance(overdue, ThemePalette.noirEssence.error),
                        "\(theme) keeps the native overdue red: \(overdue)")
            }
        }

        harness.model.sidebarMode = .journal
        await harness.settle()
        harness.model.sidebarMode = .tasks
        try await harness.waitUntil { taskTable(harness, rows: 32) != nil }
        await harness.settle()
        let returned = try #require(taskTable(harness, rows: 32))
        harness.window.makeFirstResponder(returned)
        await harness.settle()
        expectNoirEssenceTasks(try taskColors(harness, table: returned))

        try select("Podle systému", in: picker)
        await harness.settle()
    }

    private func expectNoirEssenceTasks(_ colors: TaskColors, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(isCream(colors.list), "the Task list uses the palette: \(colors.list)", sourceLocation: sourceLocation)
        #expect(colors.selection.redComponent > colors.selection.blueComponent + 0.06,
                "the selected Task is marked with the orange accent: \(colors.selection)", sourceLocation: sourceLocation)
        let appearance = NSAppearance(named: .aqua)!
        #expect(contrast(ThemePalette.noirEssence.text, on: colors.selection, in: appearance) >= 4.5,
                "the selected Task stays readable", sourceLocation: sourceLocation)
        #expect(colors.blue == 0, "no system-accent blue remains in a Task row", sourceLocation: sourceLocation)
        if let overdue = colors.overdue {
            // Thin caption strokes never reach their full colour; compare which colour they are drawn in.
            let error = srgb(ThemePalette.noirEssence.error, in: appearance)
            #expect(colorDistance(overdue, error) < colorDistance(overdue, srgb(.systemRed, in: appearance)),
                    "overdue dates use the palette's error colour: \(overdue)", sourceLocation: sourceLocation)
            #expect(contrast(error, on: colors.list, in: appearance) >= 4.5, "overdue dates are readable", sourceLocation: sourceLocation)
        } else {
            Issue.record("no overdue date is drawn", sourceLocation: sourceLocation)
        }
    }

    private func expectNoirEssenceTimeline(_ colors: TimelineColors, in view: MarkdownTextView, sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(isCream(colors.detail), "the timeline uses the palette: \(colors.detail)", sourceLocation: sourceLocation)
        #expect(isCream(colors.card), "Section cards use the palette: \(colors.card)", sourceLocation: sourceLocation)
        #expect(colorDistance(colors.card, colors.detail) > 0.02, "cards stand out from the timeline", sourceLocation: sourceLocation)
        let appearance = view.effectiveAppearance
        defer { ThemePalette.increasedContrastOverride = nil }
        for (increased, minimum) in [(false, 4.5), (true, 7.0)] {
            ThemePalette.increasedContrastOverride = increased
            for (role, color) in colors.roles {
                #expect(contrast(color, on: colors.card, in: appearance) >= minimum, "\(role) is readable on its card", sourceLocation: sourceLocation)
            }
        }
        ThemePalette.increasedContrastOverride = nil
        let text = srgb(colors.text, in: appearance)
        let reference = srgb(ThemePalette.noirEssence.text, in: appearance)
        #expect(colorDistance(text, reference) < 0.01, "read-only text follows the palette", sourceLocation: sourceLocation)
        #expect(colors.blue == 0, "the card's link uses the palette, not the system blue", sourceLocation: sourceLocation)
        let tag = srgb(try #require(colors.roles.first { $0.0 == "Tag" }?.1), in: appearance)
        #expect(tag.redComponent > tag.blueComponent + 0.2, "Tags keep their warm palette colour: \(tag)", sourceLocation: sourceLocation)
    }

    private func expectNoirEssenceSearch(_ colors: SearchColors, sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(isCream(colors.panel), "the panel uses the palette: \(colors.panel)", sourceLocation: sourceLocation)
        #expect(isCream(colors.listBackground), "results use the palette: \(colors.listBackground)", sourceLocation: sourceLocation)
        #expect(isCream(colors.header), "group headers use the palette: \(colors.header)", sourceLocation: sourceLocation)
        #expect(colors.selection.redComponent > colors.selection.blueComponent + 0.06,
                "the selected result is marked with the orange accent: \(colors.selection)", sourceLocation: sourceLocation)
        #expect(colors.highlightPixels.orange > 20, "matches are highlighted in the accent", sourceLocation: sourceLocation)
        #expect(colors.highlightPixels.blue == 0, "no system-accent highlight remains", sourceLocation: sourceLocation)
        let text = ThemePalette.noirEssence.text
        let appearance = NSAppearance(named: .aqua)!
        #expect(contrast(text, on: colors.selection, in: appearance) >= 4.5, "selected results stay readable", sourceLocation: sourceLocation)
        #expect(colorDistance(colors.selection, colors.listBackground) > 0.08, "the selection is distinguishable", sourceLocation: sourceLocation)
    }
}

struct TimelineColors {
    let detail: NSColor
    let card: NSColor
    let text: NSColor
    /// Markdown roles drawn in the card, by name.
    let roles: [(String, NSColor)]
    /// System-blue pixels in the card's actions below its Markdown.
    let blue: Int
}

/// The read-only Markdown views shown, such as Tag Timeline Sections.
@MainActor
private func readOnlyViews(_ harness: SearchPresentationHarness) -> [MarkdownTextView] {
    descendants(of: harness.hostingView).compactMap { $0 as? MarkdownTextView }.filter { !$0.isEditable }
}

@MainActor
private func visibleReadOnlyView(_ harness: SearchPresentationHarness, in scroll: NSScrollView) -> MarkdownTextView? {
    let visible = scroll.convert(scroll.bounds, to: nil)
    return readOnlyViews(harness).first { visible.contains($0.convert($0.bounds, to: nil)) }
}

@MainActor
private func timelineColors(_ harness: SearchPresentationHarness, card view: MarkdownTextView) throws -> TimelineColors {
    let image = try #require(WindowImage(harness.window))
    let frame = view.convert(view.bounds, to: nil)
    // Section cards pad their Markdown by 14 points; the timeline pads cards by 24.
    let card = try #require(image.color(at: NSPoint(x: frame.minX - 7, y: frame.midY)))
    let detail = try #require(image.color(at: NSPoint(x: frame.minX - 14 - 10, y: frame.midY)))
    let storage = try #require(view.textStorage)
    func foreground(_ text: String) throws -> NSColor {
        let range = (view.string as NSString).range(of: text)
        try #require(range.location != NSNotFound)
        return try #require(storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor)
    }
    let roles: [(String, NSColor)] = [
        ("text", try foreground("Body")), ("link", try foreground("site")),
        ("Wiki-link", try foreground("Alfa")), ("Tag", try foreground("projekt")),
        ("quotation", try foreground("A quotation")), ("completed Task", try foreground("Done task")),
    ]
    let actions = NSRect(x: frame.minX, y: frame.minY - 36, width: frame.width, height: 36)
    let blue = image.colors(in: actions).filter { $0.blueComponent - $0.redComponent > 0.4 }.count
    return TimelineColors(detail: detail, card: card, text: roles[0].1, roles: roles, blue: blue)
}

struct TaskColors {
    let list: NSColor
    let selection: NSColor
    /// The strongest red drawn in an unselected overdue row: its date.
    let overdue: NSColor?
    /// System-blue pixels in an unselected row.
    let blue: Int
}

@MainActor
private func taskTable(_ harness: SearchPresentationHarness, rows: Int) -> NSTableView? {
    harness.tables.first { table in
        (0..<table.numberOfRows).filter { table.rowView(atRow: $0, makeIfNecessary: true)?.isGroupRowStyle != true }.count == rows
    }
}

@MainActor
private func pressDown(_ harness: SearchPresentationHarness) {
    let characters = String(Character(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!))
    let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0,
        windowNumber: harness.window.windowNumber, context: nil,
        characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 125
    )
    if let event { harness.window.sendEvent(event) }
}

/// The most frequent colour, after rounding, of a set of pixels.
private func dominant(_ colors: [NSColor]) -> NSColor? {
    let key = { (c: NSColor) in [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 50).rounded()) } }
    let groups = Dictionary(grouping: colors, by: key)
    return groups.max { $0.value.count < $1.value.count }?.value.first
}

@MainActor
private func taskColors(_ harness: SearchPresentationHarness, table: NSTableView) throws -> TaskColors {
    let scroll = try #require(table.enclosingScrollView)
    let window = try #require(WindowImage(harness.window))
    let image = try #require(WindowImage(view: scroll, over: window))
    let selected = table.selectedRow
    try #require(selected >= 0)
    func windowRect(ofRow row: Int) -> NSRect { table.convert(table.rect(ofRow: row), to: nil) }
    let selection = try #require(dominant(image.colors(in: windowRect(ofRow: selected).insetBy(dx: 4, dy: 3))))
    let other = try #require((0..<table.numberOfRows).first { row in
        abs(row - selected) > 1 && table.rowView(atRow: row, makeIfNecessary: true)?.isGroupRowStyle != true
            && table.visibleRect.contains(table.rect(ofRow: row))
    })
    let pixels = image.colors(in: windowRect(ofRow: other))
    let list = try #require(dominant(pixels))
    let reds = pixels.filter { $0.redComponent - $0.greenComponent > 0.2 && $0.redComponent - $0.blueComponent > 0.2 }
    let overdue = reds.max { $0.redComponent - $0.greenComponent < $1.redComponent - $1.greenComponent }
    // The system link and accent blues; the palette's muted link blue is never this saturated.
    let blue = pixels.filter { $0.blueComponent - $0.redComponent > 0.4 }.count
    return TaskColors(list: list, selection: selection, overdue: overdue, blue: blue)
}

struct SearchColors {
    let panel: NSColor
    let listBackground: NSColor
    let header: NSColor
    let selection: NSColor
    /// Highlight-coloured pixels in an unselected result row.
    let highlightPixels: (orange: Int, blue: Int)
}

@MainActor
private func searchColors(_ harness: SearchPresentationHarness, list: NSTableView, selectedRow: Int) throws -> SearchColors {
    let field = try #require(descendants(of: harness.hostingView).compactMap { $0 as? NSTextField }
        .first { $0.placeholderString?.hasPrefix("Hledat v uložených") == true })
    let fieldFrame = field.convert(field.bounds, to: nil)
    let image = try #require(WindowImage(harness.window))
    let panel = try #require(image.color(at: NSPoint(x: fieldFrame.maxX + 6, y: fieldFrame.midY)))
    let scroll = try #require(list.enclosingScrollView)
    let visible = scroll.convert(scroll.bounds, to: nil)
    let listBackground = try #require(image.color(at: NSPoint(x: visible.maxX - 24, y: visible.minY + 6)))
    let headerRow = try #require((0..<list.numberOfRows).first { row in
        list.rowView(atRow: row, makeIfNecessary: true)?.isGroupRowStyle == true
            && list.visibleRect.intersects(list.rect(ofRow: row))
    } ?? (0..<list.numberOfRows).first { list.rowView(atRow: $0, makeIfNecessary: true)?.isGroupRowStyle == true })
    func windowRect(ofRow row: Int) -> NSRect {
        list.convert(list.rect(ofRow: row), to: nil)
    }
    let headerRect = windowRect(ofRow: headerRow)
    let header = try #require(image.color(at: NSPoint(x: headerRect.maxX - 30, y: headerRect.midY)))
    try #require(selectedRow >= 0)
    let selectedRect = windowRect(ofRow: selectedRow)
    let selection = try #require(image.color(at: NSPoint(x: selectedRect.maxX - 30, y: selectedRect.midY)))
    let other = try #require((0..<list.numberOfRows).first { row in
        row != selectedRow && list.rowView(atRow: row, makeIfNecessary: true)?.isGroupRowStyle != true
            && list.visibleRect.contains(list.rect(ofRow: row))
    })
    var orange = 0
    var blue = 0
    for color in image.colors(in: windowRect(ofRow: other)) {
        let (r, g, b) = (color.redComponent, color.greenComponent, color.blueComponent)
        guard color.luminance > 0.45 else { continue }
        if r - b > 0.12, r > g { orange += 1 }
        if b - r > 0.12 { blue += 1 }
    }
    return SearchColors(panel: panel, listBackground: listBackground, header: header, selection: selection, highlightPixels: (orange, blue))
}

/// One rendering of a window's content, sampled in window coordinates.
@MainActor
struct WindowImage {
    private let rep: NSBitmapImageRep
    private let view: NSView
    private let scale: CGFloat
    private var backdrop: [WindowImage] = []

    init?(_ window: NSWindow) {
        guard let view = window.contentView else { return nil }
        self.init(view: view)
    }

    /// Renders only one view: a window rendering can omit text that
    /// SwiftUI lists draw in their own layers.
    init?(view: NSView) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        self.rep = rep
        self.view = view
        scale = CGFloat(rep.pixelsWide) / view.bounds.width
    }

    /// Renders one view composited over what the window draws behind it.
    init?(view: NSView, over window: WindowImage) {
        self.init(view: view)
        backdrop = [window]
    }

    func color(at point: NSPoint) -> NSColor? {
        let local = view.convert(point, from: nil)
        let y = view.isFlipped ? local.y : view.bounds.height - local.y
        return pixel(x: Int(local.x * scale), y: Int(y * scale), window: point)
    }

    private func pixel(x: Int, y: Int, window point: NSPoint) -> NSColor? {
        guard let top = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
        guard let under = backdrop.first, top.alphaComponent < 1, let below = under.color(at: point) else { return top }
        let a = top.alphaComponent
        func over(_ t: CGFloat, _ b: CGFloat) -> CGFloat { t * a + b * (1 - a) }
        return NSColor(srgbRed: over(top.redComponent, below.redComponent), green: over(top.greenComponent, below.greenComponent),
                       blue: over(top.blueComponent, below.blueComponent), alpha: 1)
    }

    /// Every pixel in a window rectangle.
    func colors(in rect: NSRect) -> [NSColor] {
        let local = view.convert(rect, from: nil)
        let minY = view.isFlipped ? local.minY : view.bounds.height - local.maxY
        var result: [NSColor] = []
        for y in stride(from: Int(minY * scale), to: Int((minY + local.height) * scale), by: 1) {
            for x in stride(from: Int(local.minX * scale), to: Int(local.maxX * scale), by: 1) {
                let point = view.convert(NSPoint(x: CGFloat(x) / scale, y: view.isFlipped ? CGFloat(y) / scale : view.bounds.height - CGFloat(y) / scale), to: nil)
                if let color = pixel(x: x, y: y, window: point) { result.append(color) }
            }
        }
        return result
    }
}

extension NSColor {
    /// Relative luminance of an sRGB colour, 0 (black) to 1 (white).
    var luminance: Double {
        let c = usingColorSpace(.sRGB) ?? self
        return Double(0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent)
    }
}
