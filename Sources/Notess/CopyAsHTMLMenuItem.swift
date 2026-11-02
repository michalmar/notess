import AppKit
import NotessEditor

/// Edit ▸ Kopírovat jako HTML, right after Copy.
///
/// An AppKit item sent through the responder chain, so the focused Markdown
/// view enables it only for a current selection, which a SwiftUI command
/// cannot do. SwiftUI may rebuild the Edit menu, so installing is idempotent
/// and repeated whenever the app updates.
@MainActor
enum CopyAsHTMLMenuItem {
    static let title = "Kopírovat jako HTML"

    /// Puts the item after Copy in the menu bar's menu that has Copy.
    /// Returns whether the menu changed.
    @discardableResult
    static func install(in mainMenu: NSMenu?) -> Bool {
        for top in mainMenu?.items ?? [] {
            guard let menu = top.submenu,
                  let copy = menu.items.firstIndex(where: { $0.action == #selector(NSText.copy(_:)) }) else { continue }
            let action = #selector(MarkdownTextView.copyAsHTML(_:))
            if let existing = menu.items.firstIndex(where: { $0.action == action }) {
                if existing == copy + 1 { return false }
                let item = menu.items[existing]
                menu.removeItem(at: existing)
                menu.insertItem(item, at: existing < copy ? copy : copy + 1)
                return true
            }
            menu.insertItem(NSMenuItem(title: title, action: action, keyEquivalent: ""), at: copy + 1)
            return true
        }
        return false
    }
}
