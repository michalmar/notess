import SwiftUI

struct NoteCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Uložit") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.document == nil)
        }
    }
}
