import AppKit
import SwiftUI

extension View {
    func themedListSelection() -> some View {
        background(ThemedListSelection())
    }
}

/// Replaces only native selection drawing, not the table, its rows or layout.
/// A separate drawing view avoids changing SwiftUI's row views during layout.
private struct ThemedListSelection: NSViewRepresentable {
    @Environment(\.themePalette) private var palette

    func makeNSView(context: Context) -> ListSelectionAnchor { ListSelectionAnchor() }

    func updateNSView(_ view: ListSelectionAnchor, context: Context) {
        view.palette = palette
        view.scheduleUpdate()
    }

    static func dismantleNSView(_ view: ListSelectionAnchor, coordinator: ()) {
        view.restore()
    }
}

private final class ListSelectionAnchor: NSView {
    var palette: ThemePalette?
    private weak var table: NSTableView?
    private var nativeStyle: NSTableView.SelectionHighlightStyle?
    private var observation: NSKeyValueObservation?
    private var drawing: ListSelectionDrawing?
    private var updateScheduled = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleUpdate()
    }

    override func layout() {
        super.layout()
        if table == nil || table?.window !== window { scheduleUpdate() }
    }

    func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            updateScheduled = false
            update()
        }
    }

    private func update() {
        guard window != nil else { return }
        if let table, table.window !== window {
            restore()
            self.table = nil
            nativeStyle = nil
        }
        if table == nil {
            let frame = convert(bounds, to: nil)
            var ancestor = superview
            while let container = ancestor {
                if let found = findTable(in: container, overlapping: frame) {
                    table = found
                    nativeStyle = found.selectionHighlightStyle
                    break
                }
                ancestor = container.superview
            }
        }
        guard let table else { return }
        if let palette {
            if drawing == nil {
                let drawing = ListSelectionDrawing(frame: table.bounds)
                drawing.table = table
                drawing.autoresizingMask = [.width, .height]
                table.addSubview(drawing, positioned: .below, relativeTo: nil)
                self.drawing = drawing
                observation = table.observe(\.selectedRowIndexes) { [weak drawing] _, _ in
                    MainActor.assumeIsolated { drawing?.needsDisplay = true }
                }
            }
            drawing?.palette = palette
            drawing?.needsDisplay = true
            setHighlightStyle(.none, on: table)
        } else {
            restore()
        }
    }

    func restore() {
        observation = nil
        drawing?.removeFromSuperview()
        drawing = nil
        if let table, let nativeStyle {
            setHighlightStyle(nativeStyle, on: table)
        }
    }

    private func setHighlightStyle(_ style: NSTableView.SelectionHighlightStyle, on table: NSTableView) {
        guard table.selectionHighlightStyle != style else { return }
        let scroll = table.enclosingScrollView
        let origin = scroll?.contentView.bounds.origin
        table.selectionHighlightStyle = style
        // AppKit reloads the table when this drawing policy changes. Finish
        // that layout once, outside SwiftUI's update, before restoring its viewport.
        table.layoutSubtreeIfNeeded()
        if let scroll, let origin {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private func findTable(in view: NSView, overlapping frame: NSRect) -> NSTableView? {
        func tables(in view: NSView) -> [NSTableView] {
            if let table = view as? NSTableView { return [table] }
            return view.subviews.flatMap { tables(in: $0) }
        }
        func overlap(_ table: NSTableView) -> CGFloat {
            guard !table.isHiddenOrHasHiddenAncestor, let scroll = table.enclosingScrollView else { return 0 }
            let rect = scroll.convert(scroll.bounds, to: nil)
            let intersection = rect.intersection(frame)
            guard !intersection.isNull else { return 0 }
            let area = intersection.width * intersection.height
            return area / max(1, rect.width * rect.height + frame.width * frame.height - area)
        }
        return tables(in: view).filter { overlap($0) > 0.7 }.max { overlap($0) < overlap($1) }
    }
}

private final class ListSelectionDrawing: NSView {
    weak var table: NSTableView?
    var palette: ThemePalette?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let table, let palette else { return }
        palette.selection.setFill()
        for index in table.selectedRowIndexes {
            let rect = table.rect(ofRow: index).insetBy(dx: 4, dy: 1)
            guard rect.intersects(dirtyRect) else { continue }
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        }
    }
}
