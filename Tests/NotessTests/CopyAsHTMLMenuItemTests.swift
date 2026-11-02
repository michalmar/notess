import AppKit
import NotessEditor
import Testing
@testable import Notess

@MainActor
@Suite("Edit menu Copy as HTML")
struct CopyAsHTMLMenuItemTests {
    private func makeMainMenu() -> (NSMenu, NSMenu) {
        let mainMenu = NSMenu()
        let edit = NSMenu(title: "Úpravy")
        edit.addItem(withTitle: "Zpět", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Vyjmout", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Kopírovat", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Vložit", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        mainMenu.addItem(withTitle: "Notess", action: nil, keyEquivalent: "").submenu = NSMenu(title: "Notess")
        mainMenu.addItem(withTitle: "Úpravy", action: nil, keyEquivalent: "").submenu = edit
        return (mainMenu, edit)
    }

    @Test("the item follows Copy, goes to the focused view and has no shortcut of its own")
    func installsAfterCopy() throws {
        let (mainMenu, edit) = makeMainMenu()

        #expect(CopyAsHTMLMenuItem.install(in: mainMenu))

        #expect(edit.items.map(\.title) == ["Zpět", "", "Vyjmout", "Kopírovat", "Kopírovat jako HTML", "Vložit"])
        let item = edit.items[4]
        #expect(item.action == #selector(MarkdownTextView.copyAsHTML(_:)))
        #expect(item.target == nil)
        #expect(item.keyEquivalent.isEmpty)
        #expect(edit.items[3].keyEquivalent == "c")
    }

    @Test("installing again neither duplicates nor misplaces the item")
    func idempotent() {
        let (mainMenu, edit) = makeMainMenu()
        CopyAsHTMLMenuItem.install(in: mainMenu)

        #expect(!CopyAsHTMLMenuItem.install(in: mainMenu))

        let moved = edit.items[4]
        edit.removeItem(moved)
        edit.insertItem(moved, at: 0)
        #expect(CopyAsHTMLMenuItem.install(in: mainMenu))
        #expect(edit.items.map(\.title) == ["Zpět", "", "Vyjmout", "Kopírovat", "Kopírovat jako HTML", "Vložit"])
    }
}
