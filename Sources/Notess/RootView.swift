import AppKit
import NotessCore
import NotessEditor
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    let onCloseTab: (NoteDocument.ID) -> Void

    var body: some View {
        ZStack {
            if model.vault != nil {
                NavigationSplitView {
                    SidebarView(model: model)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 400)
                } detail: {
                    HStack(spacing: 0) {
                        switch model.sidebarMode {
                        case .journal:
                            journalDetail
                        case .tags:
                            TagTimelineView(
                                browser: model.tagTimeline,
                                settings: model.settings,
                                isIndexing: model.isIndexing,
                                indexFailure: model.searchIndexFailure,
                                noteURL: model.noteURL(for:),
                                openImagePreview: model.presentImagePreview,
                                open: model.openTimelineSection,
                                openTag: model.openTagTimeline
                            )
                        }
                        if model.isBrainConversationPresented {
                            Divider()
                            BrainConversationPanel(
                                state: model.brainConversation,
                                isBrainRunActive: model.isBrainRunActive,
                                hasUnsavedChanges: model.hasUnsavedChanges,
                                onAsk: { model.askBrainConversation($0) },
                                onStop: model.stopBrainConversationTurn,
                                onClose: { model.isBrainConversationPresented = false }
                            )
                            .frame(width: 340)
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.reconcileWithDisk()
                    model.synchronizeSearchIndex()
                }
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        BrainRunToolbarItems(model: model)
                    }
                }
            } else {
                VaultSetupView { url in model.chooseVault(at: url) }
            }

            if model.isQuickOpenPresented, let vault = model.vault {
                Color.black.opacity(0.2)
                    .ignoresSafeArea()
                QuickOpenView(
                    vault: vault,
                    open: model.openNote(relativePath:),
                    dismiss: { model.isQuickOpenPresented = false }
                )
            }

            if let search = model.globalSearch {
                Color.black.opacity(0.2)
                    .ignoresSafeArea()
                    .onTapGesture { model.isSearchPresented = false }
                SearchView(
                    search: search,
                    isIndexing: model.isIndexing,
                    revision: model.searchIndexRevision,
                    open: model.openSearchResult,
                    dismiss: { model.isSearchPresented = false }
                )
            }

            if let content = model.imagePreview.content {
                ImagePreviewOverlay(
                    content: content,
                    onDismiss: model.imagePreview.dismiss
                )
                .zIndex(10)
            }
        }
        .background(KeyWindowObserver { model.isNoteWindowKey = $0 })
        .confirmationDialog(
            model.noteDeletionConfirmation.map { "Smazat \($0.displayName)?" } ?? "Smazat poznámku?",
            isPresented: Binding(
                get: { model.noteDeletionConfirmation != nil },
                set: { if !$0 { model.cancelNoteDeletion() } }
            ),
            titleVisibility: .visible,
            presenting: model.noteDeletionConfirmation,
            actions: deletionActions,
            message: { Text(deletionMessage(for: $0)) }
        )
        .alert(
            "Chyba",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(model.errorMessage ?? "") }
        )
    }

    @ViewBuilder
    private func deletionActions(for confirmation: NoteDeletionConfirmation) -> some View {
        switch confirmation.kind {
        case .savedFile:
            Button("Přesunout do Koše", role: .destructive) {
                model.confirmNoteDeletion(.moveToTrash)
            }
        case .dirtyFile:
            Button("Uložit a přesunout do Koše", role: .destructive) {
                model.confirmNoteDeletion(.saveAndMoveToTrash)
            }
            Button("Zahodit změny a přesunout do Koše", role: .destructive) {
                model.confirmNoteDeletion(.discardChangesAndMoveToTrash)
            }
        case .draftDailyEntry:
            Button("Zahodit rozepsaný záznam", role: .destructive) {
                model.confirmNoteDeletion(.discardDraft)
            }
        }
        Button("Zrušit", role: .cancel) {
            model.cancelNoteDeletion()
        }
    }

    private func deletionMessage(for confirmation: NoteDeletionConfirmation) -> String {
        let referenceWarning = "Příchozí wiki-odkazy a citace mohou přestat fungovat."
        switch confirmation.kind {
        case .savedFile:
            return "Soubor bude přesunut do systémového Koše, odkud jej lze obnovit. \(referenceWarning)"
        case .dirtyFile:
            return "Poznámka obsahuje neuložené změny. Zvolte, zda je před přesunutím do systémového Koše uložit, nebo zahodit. \(referenceWarning)"
        case .draftDailyEntry:
            return "Tento Daily Entry ještě nebyl uložen. Jeho rozepsaný obsah bude zahoden bez vytvoření souboru nebo položky v Koši. \(referenceWarning)"
        }
    }

    private var journalDetail: some View {
        VStack(spacing: 0) {
            if !model.tabSession.documents.isEmpty {
                NoteTabBar(
                    session: model.tabSession,
                    onSelect: model.selectTab,
                    onClose: onCloseTab
                )
                Divider()
            }
            if let document = model.document {
                ExternalChangeBar(
                    document: document,
                    onReload: { model.reloadFromDisk(documentID: document.id) },
                    onSave: { model.save(documentID: document.id) },
                    onClose: { onCloseTab(document.id) }
                )
                NoteEditorScreen(
                    document: document,
                    settings: model.settings,
                    reveal: model.reveal,
                    backlinks: model.backlinks,
                    onOpenWikiLink: { model.openWikiLink($0) },
                    onOpenTag: { model.openTagTimeline($0) },
                    onOpenBacklink: { model.openBacklink($0) },
                    onPasteImageFailure: { error in
                        model.errorMessage = "Obrázek se nepodařilo vložit: \(error.localizedDescription)"
                    },
                    onOpenImagePreview: model.presentImagePreview,
                    onImageLoadFailure: {
                        model.errorMessage = $0
                    },
                    tagSuggestionSource: model.tagSuggestionSource,
                    onTagSuggestionFailure: { error in
                        model.errorMessage = "Návrhy štítků se nepodařilo načíst: \(error.localizedDescription)"
                    },
                    // Overlays own the keyboard; closing one hands focus back to the editor.
                    isImagePreviewPresented: model.imagePreview.content != nil || model.isSearchPresented
                )
            } else {
                ContentUnavailableView(
                    "Žádná otevřená poznámka",
                    systemImage: "doc.text"
                )
            }
        }
    }
}

struct VaultSetupView: View {
    let onChoose: (URL) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Vyberte Vault")
                .font(.title2.weight(.semibold))
            Text("Notess ukládá všechny poznámky jako Markdown soubory do jedné složky – Vaultu.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
            Button("Vybrat složku…") {
                if let url = VaultPicker.chooseFolder() { onChoose(url) }
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Reports whether the window hosting this view is the key window; a Settings
/// window, sheet or alert in front makes it false.
private struct KeyWindowObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else {
                report(false)
                return
            }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self, weak window] _ in
                    self?.report(window?.isKeyWindow ?? false)
                })
            }
            report(window.isKeyWindow)
        }

        private func report(_ isKey: Bool) {
            DispatchQueue.main.async { [onChange] in onChange(isKey) }
        }
    }
}
