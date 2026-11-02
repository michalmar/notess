import AppKit
import NotessEditor
import Testing
@testable import Notess

@MainActor
@Suite("Source-line Edit menu")
struct SourceLineMenuTests {
    @Test("Edit exposes four responder commands with Option-arrow shortcuts, without duplicating them")
    func editMenu() {
        let main = NSMenu()
        let edit = NSMenu(title: "Edit")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        SourceLineMenuController.install(in: main)
        SourceLineMenuController.install(in: main)
        #expect(edit.items.map(\.title) == [
            "Copy", "Kopírovat jako HTML", "Paste", "", "Přesunout řádek nahoru", "Přesunout řádek dolů",
            "Duplikovat řádek nad", "Duplikovat řádek pod",
        ])
        let commands = Array(edit.items.suffix(4))
        #expect(commands.map(\.keyEquivalent) == ["\u{F700}", "\u{F701}", "\u{F700}", "\u{F701}"])
        #expect(commands.map(\.keyEquivalentModifierMask) == [.option, .option, [.option, .shift], [.option, .shift]])
        #expect(commands.allSatisfy { $0.target == nil })
        #expect(commands.map(\.action) == SourceLineCommand.all.map { Optional($0.action) })
    }
}
