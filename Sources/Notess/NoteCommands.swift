import AppKit
import NotessEditor
import SwiftUI

struct NoteCommands: Commands {
    let model: AppModel
    let onCloseActiveTab: () -> Void

    var body: some Commands {
        let isPreviewPresented = model.imagePreview.content != nil
        CommandGroup(replacing: .newItem) {
            Button("Nová poznámka") { model.newFreeNote() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.vault == nil || isPreviewPresented)
            Button("Dnešní záznam") { model.openToday() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(model.vault == nil || isPreviewPresented)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Uložit") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(
                    model.document == nil
                        || model.document?.isReadOnly == true
                        || isPreviewPresented
                )
        }
        CommandGroup(after: .saveItem) {
            Button("Rychle otevřít…") { model.presentQuickOpen() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(model.vault == nil || isPreviewPresented)
            Button("Hledat…") { model.presentSearch() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(model.vault == nil || isPreviewPresented)
            Button("Přegenerovat index hledání") { model.rebuildSearchIndex() }
                .disabled(model.vault == nil || model.isIndexing || isPreviewPresented)
            Button("Zavřít tab", action: onCloseActiveTab)
                .keyboardShortcut("w", modifiers: .command)
                .disabled(model.document == nil || model.sidebarMode == .tags || isPreviewPresented)
        }
        CommandMenu("Tabulka") {
            // Sent to the focused editor, which beeps when the caret is not in a table.
            ForEach(Array(TableEditCommand.groups.enumerated()), id: \.offset) { group in
                if group.offset > 0 { Divider() }
                ForEach(group.element) { command in
                    Button(command.title) {
                        if !NSApp.sendAction(command.action, to: nil, from: nil) { NSSound.beep() }
                    }
                    .keyboardShortcut(command.key, modifiers: command.modifiers)
                    .disabled(
                        model.document == nil
                            || model.document?.isReadOnly == true
                            || isPreviewPresented
                    )
                }
            }
        }
    }
}
