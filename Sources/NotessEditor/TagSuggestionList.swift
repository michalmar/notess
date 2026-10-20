import AppKit

/// The anchored list of Tag suggestions shown under the Tag being typed.
///
/// It never becomes first responder, so the editor keeps focus and receives
/// every key. Rows read `#tag`; the selected row is the one Tab accepts.
@MainActor
final class TagSuggestionList: NSView {
    static let maximumVisibleRows = 8
    static let width: CGFloat = 220
    private static let rowHeight: CGFloat = 22
    private static let verticalInset: CGFloat = 4

    private(set) var tags: [String] = []
    private(set) var selectedIndex: Int?

    private let background = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private let tableView = TableView()

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
        tableView.setAccessibilityLabel("Návrhy štítků")

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
        setAccessibilityRole(.group)
        setAccessibilityLabel("Návrhy štítků")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The height that shows up to `maximumVisibleRows` rows; more scroll.
    var preferredHeight: CGFloat {
        CGFloat(min(tags.count, Self.maximumVisibleRows)) * Self.rowHeight + 2 * Self.verticalInset
    }

    /// Shows `tags` (normalised names, without `#`) with `selectedIndex` selected.
    func show(_ tags: [String], selectedIndex: Int?) {
        self.tags = tags
        self.selectedIndex = selectedIndex.flatMap { tags.indices.contains($0) ? $0 : nil }
        tableView.reloadData()
        applySelection()
    }

    /// Highlights row `index`, scrolling it into view.
    func select(_ index: Int) {
        guard tags.indices.contains(index) else { return }
        selectedIndex = index
        applySelection()
    }

    private func applySelection() {
        if let index = selectedIndex {
            tableView.selectRowIndexes([index], byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
        } else {
            tableView.deselectAll(nil)
        }
    }

    /// Keeps the highlighted row in view after the list is resized.
    func scrollSelectionToVisible() {
        if let selectedIndex { tableView.scrollRowToVisible(selectedIndex) }
    }

    /// Indexes of the rows wholly in view, i.e. not scrolled away.
    var rowsInView: [Int] {
        layoutSubtreeIfNeeded()
        let insets = scrollView.contentInsets
        var visible = scrollView.contentView.bounds
        visible.origin.y += insets.top
        visible.size.height -= insets.top + insets.bottom
        return tags.indices.filter { visible.insetBy(dx: 0, dy: -0.5).contains(tableView.rect(ofRow: $0)) }
    }

    private final class TableView: NSTableView {
        override var acceptsFirstResponder: Bool { false }
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
        let title = "#" + tags[row]
        cell.textField?.stringValue = title
        cell.setAccessibilityLabel(title)
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        // Selection follows the editor's keyboard state only (mouse browsing is a separate step).
        row == selectedIndex
    }
}
