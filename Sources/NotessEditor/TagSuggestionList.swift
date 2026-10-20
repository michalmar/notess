import AppKit

/// The anchored list of Tag suggestions shown under the Tag being typed.
///
/// It never becomes first responder, so the editor keeps focus and receives
/// every key. Rows read `#tag`; the selected row is the one Tab accepts, and
/// clicking a row chooses it. Assistive technology sees a list of `#tag`
/// items with the selected one marked; pressing an item chooses it.
@MainActor
final class TagSuggestionList: NSView {
    static let maximumVisibleRows = 8
    static let width: CGFloat = 220
    static let rowHeight: CGFloat = 22
    private static let verticalInset: CGFloat = 4
    private static let accessibilityName = "Návrhy štítků"

    private(set) var tags: [String] = []
    private(set) var selectedIndex: Int?
    /// Told the row the user clicked (or pressed through accessibility).
    var onChoose: ((Int) -> Void)?

    private let background = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private let tableView = TableView()
    private var accessibilityRows: [RowElement] = []
    /// The Tag last announced as selected, so each change is announced once.
    private var announcedTag: String?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.rowHeight))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor

        background.material = .menu
        background.state = .active
        background.blendingMode = .withinWindow
        background.frame = bounds
        background.autoresizingMask = [.width, .height]
        addSubview(background)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tag"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.refusesFirstResponder = true
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.onClick = { [weak self] row in self?.choose(row) }

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.contentInsets = NSEdgeInsets(top: Self.verticalInset, left: 0, bottom: Self.verticalInset, right: 0)
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)

        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel(Self.accessibilityName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The height that shows up to `maximumVisibleRows` rows; more scroll.
    var preferredHeight: CGFloat {
        height(forRows: min(tags.count, Self.maximumVisibleRows))
    }

    /// The height that shows `rows` rows.
    func height(forRows rows: Int) -> CGFloat {
        CGFloat(rows) * Self.rowHeight + 2 * Self.verticalInset
    }

    /// The height of the most whole rows (at least one, at most the preferred
    /// number) that fit in `space`.
    func height(fitting space: CGFloat) -> CGFloat {
        let fitting = Int(((space - 2 * Self.verticalInset) / Self.rowHeight).rounded(.down))
        return height(forRows: max(1, min(fitting, tags.count, Self.maximumVisibleRows)))
    }

    /// Shows `tags` (normalised names, without `#`) with `selectedIndex` selected.
    func show(_ tags: [String], selectedIndex: Int?) {
        self.tags = tags
        self.selectedIndex = selectedIndex.flatMap { tags.indices.contains($0) ? $0 : nil }
        accessibilityRows = tags.indices.map { RowElement(list: self, index: $0, label: "#" + tags[$0]) }
        tableView.reloadData()
        applySelection()
        NSAccessibility.post(element: self, notification: .rowCountChanged)
        selectionDidChange()
    }

    /// Highlights row `index`, scrolling it into view.
    func select(_ index: Int) {
        guard tags.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        applySelection()
        selectionDidChange()
    }

    private func applySelection() {
        if let index = selectedIndex {
            tableView.selectRowIndexes([index], byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
        } else {
            tableView.deselectAll(nil)
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        announcedTag = nil
        selectionDidChange()
    }

    /// Tells assistive technology which suggestion is selected; the editor
    /// keeps focus, so a newly selected Tag is announced.
    private func selectionDidChange() {
        guard superview != nil, let selectedIndex, tags[selectedIndex] != announcedTag else { return }
        announcedTag = tags[selectedIndex]
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        NSAccessibility.post(
            element: self,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "#" + tags[selectedIndex],
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    /// Keeps the highlighted row in view after the list is resized.
    func scrollSelectionToVisible() {
        if let selectedIndex { tableView.scrollRowToVisible(selectedIndex) }
    }

    /// Indexes of the rows wholly in view, i.e. not scrolled away.
    var rowsInView: [Int] {
        layoutSubtreeIfNeeded()
        let visible = visibleRowArea
        return tags.indices.filter { visible.insetBy(dx: 0, dy: -0.5).contains(tableView.rect(ofRow: $0)) }
    }

    /// The part of the table not hidden by scrolling, in table coordinates.
    private var visibleRowArea: NSRect {
        let insets = scrollView.contentInsets
        var visible = scrollView.contentView.bounds
        visible.origin.y += insets.top
        visible.size.height -= insets.top + insets.bottom
        return visible
    }

    private func choose(_ row: Int) {
        guard tags.indices.contains(row) else { return }
        onChoose?(row)
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? { accessibilityRows }

    override func accessibilitySelectedChildren() -> [Any]? {
        selectedIndex.map { [accessibilityRows[$0]] } ?? []
    }

    override func accessibilityVisibleChildren() -> [Any]? {
        rowsInView.map { accessibilityRows[$0] }
    }

    /// Screen frame of row `index`, clipped to the visible part of the list.
    fileprivate func screenFrame(ofRow index: Int) -> NSRect {
        guard let window, tags.indices.contains(index) else { return .zero }
        let row = tableView.rect(ofRow: index).intersection(visibleRowArea)
        let rect = row.isNull ? tableView.rect(ofRow: index) : row
        return window.convertToScreen(tableView.convert(rect, to: nil))
    }

    /// One suggestion as assistive technology sees it.
    private final class RowElement: NSAccessibilityElement {
        // Assistive technology may keep a row longer than the list.
        private weak var list: TagSuggestionList?
        private let index: Int

        init(list: TagSuggestionList, index: Int, label: String) {
            self.list = list
            self.index = index
            super.init()
            setAccessibilityRole(.row)
            setAccessibilityLabel(label)
            setAccessibilityParent(list)
        }

        // Accessibility asks on the main thread.
        override func accessibilityFrame() -> NSRect {
            let (list, index) = (list, index)
            return MainActor.assumeIsolated { list?.screenFrame(ofRow: index) ?? .zero }
        }

        override func isAccessibilitySelected() -> Bool {
            let (list, index) = (list, index)
            return MainActor.assumeIsolated { list?.selectedIndex == index }
        }

        override func accessibilityIndex() -> Int { index }

        override func accessibilityPerformPress() -> Bool {
            let (list, index) = (list, index)
            guard let list else { return false }
            MainActor.assumeIsolated { list.choose(index) }
            return true
        }
    }

    // MARK: Table

    /// Never takes focus and chooses a row on mouse-up over the row the
    /// mouse went down on, without the table's own selection tracking.
    private final class TableView: NSTableView {
        var onClick: ((Int) -> Void)?
        private var pressedRow: Int?

        override var acceptsFirstResponder: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            super.hitTest(point) == nil ? nil : self
        }

        override func mouseDown(with event: NSEvent) {
            let row = self.row(at: convert(event.locationInWindow, from: nil))
            pressedRow = row >= 0 ? row : nil
        }

        override func mouseDragged(with event: NSEvent) {}

        override func mouseUp(with event: NSEvent) {
            defer { pressedRow = nil }
            guard let pressedRow, row(at: convert(event.locationInWindow, from: nil)) == pressedRow else { return }
            onClick?(pressedRow)
        }
    }

    /// Draws the selection emphasised although the table is never first responder.
    private final class RowView: NSTableRowView {
        override var isEmphasized: Bool {
            get { true }
            set {}
        }
    }
}

extension TagSuggestionList: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { tags.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        RowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("TagSuggestionCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            label.font = .menuFont(ofSize: 0)
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -10),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.textField?.stringValue = "#" + tags[row]
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        // Selection follows the editor's highlight only; clicks choose a row instead.
        row == selectedIndex
    }
}
