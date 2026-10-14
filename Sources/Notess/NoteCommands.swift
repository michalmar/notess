import SwiftUI

struct NoteCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Uložit") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.document == nil)
        }
        CommandGroup(after: .newItem) {
            Button("Změnit Vault…") {
                if let url = VaultPicker.chooseFolder() {
                    model.chooseVault(at: url)
                }
            }
            .disabled(!model.canChangeVault)
        }
    }
}
