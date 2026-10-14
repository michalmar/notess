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
                .disabled(model.document == nil || model.document?.isReadOnly == true)
        }
        CommandGroup(after: .saveItem) {
            Button("Rychle otevřít…") { model.presentQuickOpen() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(model.vault == nil)
            Button("Hledat…") { model.presentSearch() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(model.vault == nil)
            Button("Přegenerovat index hledání") { model.rebuildSearchIndex() }
                .disabled(model.vault == nil || model.isIndexing)
            Button("Zavřít tab", action: onCloseActiveTab)
                .keyboardShortcut("w", modifiers: .command)
                .disabled(model.document == nil)
        }
    }
}
