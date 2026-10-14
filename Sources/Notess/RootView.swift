import NotessCore
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    let onCloseTab: (NoteDocument.ID) -> Void

    var body: some View {
        Group {
            if model.vault == nil {
                VaultSetupView { url in model.chooseVault(at: url) }
            } else {
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
                        NoteEditorScreen(document: document)
                    } else {
                        ContentUnavailableView(
                            "Žádná otevřená poznámka",
                            systemImage: "doc.text"
                        )
                    }
                }
            }
        }
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
