import SwiftUI

struct NoteCommands: Commands {
    let model: AppModel
    let onCloseActiveTab: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nová poznámka") { model.newFreeNote() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.vault == nil)
            Button("Dnešní záznam") { model.openToday() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(model.vault == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Uložit") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.document == nil)
        }
        CommandGroup(after: .saveItem) {
            Button("Rychle otevřít…") { model.presentQuickOpen() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(model.vault == nil)
            Button("Zavřít tab", action: onCloseActiveTab)
                .keyboardShortcut("w", modifiers: .command)
                .disabled(model.document == nil)
        }
    }
}
