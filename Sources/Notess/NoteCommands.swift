import AppKit
import NotessEditor
import SwiftUI

/// The two searches: ⇧⌘F searches every saved note, ⌘F only the open note.
enum SearchCommand: CaseIterable {
    case globalSearch
    case findInNote

    var key: KeyEquivalent { "f" }

    var modifiers: EventModifiers {
        switch self {
        case .globalSearch: [.command, .shift]
        case .findInNote: .command
        }
    }

    @MainActor
    func perform(on model: AppModel, showFindInEditor: @MainActor () -> Void = SearchCommand.showFindInEditor) {
        switch self {
        case .globalSearch:
            model.presentSearch()
        case .findInNote:
            showFindInEditor()
        }
    }

    /// Sent to the focused editor, which opens its find bar.
    @MainActor
    static func showFindInEditor() {
        if !NSApp.sendAction(#selector(MarkdownTextView.showFind(_:)), to: nil, from: nil) {
            NSSound.beep()
        }
    }
}

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
            Button("Hledat…") { SearchCommand.globalSearch.perform(on: model) }
                .keyboardShortcut(SearchCommand.globalSearch.key, modifiers: SearchCommand.globalSearch.modifiers)
                .disabled(model.vault == nil || isPreviewPresented)
            Button("Najít v poznámce…") { SearchCommand.findInNote.perform(on: model) }
                .keyboardShortcut(SearchCommand.findInNote.key, modifiers: SearchCommand.findInNote.modifiers)
            .disabled(model.document == nil || model.sidebarMode == .tags || isPreviewPresented)
            Button("Přegenerovat index hledání") { model.rebuildSearchIndex() }
                .disabled(model.vault == nil || model.isIndexing || isPreviewPresented)
            Button("Zavřít tab", action: onCloseActiveTab)
                .keyboardShortcut("w", modifiers: .command)
                .disabled(model.document == nil || model.sidebarMode == .tags || isPreviewPresented)
        }
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Sbalit nebo rozbalit nadpis") {
                if !NSApp.sendAction(#selector(MarkdownTextView.toggleHeadingFold(_:)), to: nil, from: nil) {
                    NSSound.beep()
                }
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(isPreviewPresented || model.vault == nil)
            // ⌘= is handled by the app delegate: this shortcut is ⇧⌘= on a US keyboard.
            Button("Zvětšit text") { model.zoomInText() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!model.canZoomInText)
            Button("Zmenšit text") { model.zoomOutText() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!model.canZoomOutText)
            Button("Skutečná velikost textu") { model.resetTextZoom() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!model.isTextZoomRoutable)
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
                            || model.sidebarMode == .tags
                            || isPreviewPresented
                    )
                }
            }
        }
    }
}
