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
            case "Dark":
                #expect(colors.panel.luminance < 0.3, "dark panel: \(colors.panel)")
                #expect(colors.listBackground.luminance < 0.3, "dark results: \(colors.listBackground)")
            default:
                #expect(!isCream(colors.panel) && !isCream(colors.listBackground), "\(theme) is native: \(colors.panel)")
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

    init?(_ window: NSWindow) {
        guard let view = window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        self.rep = rep
        self.view = view
        scale = CGFloat(rep.pixelsWide) / view.bounds.width
    }

    func color(at point: NSPoint) -> NSColor? {
        let local = view.convert(point, from: nil)
        let y = view.isFlipped ? local.y : view.bounds.height - local.y
        return rep.colorAt(x: Int(local.x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB)
    }

    /// Every pixel in a window rectangle.
    func colors(in rect: NSRect) -> [NSColor] {
        let local = view.convert(rect, from: nil)
        let minY = view.isFlipped ? local.minY : view.bounds.height - local.maxY
        var result: [NSColor] = []
        for y in stride(from: Int(minY * scale), to: Int((minY + local.height) * scale), by: 1) {
            for x in stride(from: Int(local.minX * scale), to: Int(local.maxX * scale), by: 1) {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) { result.append(color) }
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
