import AppKit
import NotessCore

/// Why Copy as HTML left the clipboard unchanged.
public enum CopyAsHTMLError: LocalizedError, Equatable {
    /// The selection contains an image stored with the note, which cannot be
    /// embedded yet.
    case unsupportedLocalImage(source: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedLocalImage(let source):
            "Obrázek „\(source)“ zatím nelze zkopírovat jako HTML. Schránka zůstala beze změny."
        }
    }
}

extension MarkdownTextView {
    static let copyAsHTMLTitle = "Kopírovat jako HTML"

    /// Puts the selection on the clipboard as rendered HTML plus readable
    /// plain text. The export is prepared completely before the clipboard is
    /// replaced, so a failure leaves it as it was.
    @objc public func copyAsHTML(_ sender: Any?) {
        guard canCopyAsHTML else {
            NSSound.beep()
            return
        }
        let output: MarkdownExport.Output
        do {
            output = try MarkdownExport.render(string, selection: selectedRange(), embedLocalImage: embedLocalImageForHTML)
        } catch {
            NSSound.beep()
            onCopyAsHTMLFailure?(error)
            return
        }
        guard !output.isEmpty else {
            NSSound.beep()
            return
        }
        pasteboard.clearContents()
        pasteboard.setData(Data(output.html.utf8), forType: .html)
        pasteboard.setString(output.plainText, forType: .string)
    }

    /// The `src` that embeds a selected local image in the copied HTML.
    ///
    /// Local images cannot be embedded yet, so they fail the whole copy
    /// rather than being dropped or replaced with their description.
    func embedLocalImageForHTML(_ image: MarkdownExport.LocalImage) throws -> String {
        throw CopyAsHTMLError.unsupportedLocalImage(source: image.source)
    }

    /// Enabled for one nonempty selection in selectable text.
    var canCopyAsHTML: Bool {
        isSelectable && selectedRanges.count == 1 && selectedRange().length > 0
    }

    /// Whether Copy as HTML is enabled, or `nil` for any other action.
    func validateCopyAsHTML(_ action: Selector?) -> Bool? {
        action == #selector(copyAsHTML(_:)) ? canCopyAsHTML : nil
    }

    /// Adds Copy as HTML right after Copy in the context menu.
    func addCopyAsHTMLItem(to menu: NSMenu) {
        guard isSelectable, !menu.items.contains(where: { $0.action == #selector(copyAsHTML(_:)) }) else { return }
        let item = NSMenuItem(title: Self.copyAsHTMLTitle, action: #selector(copyAsHTML(_:)), keyEquivalent: "")
        item.target = self
        if let copy = menu.items.firstIndex(where: { $0.action == #selector(copy(_:)) }) {
            menu.insertItem(item, at: copy + 1)
        } else {
            menu.addItem(item)
        }
    }
}
