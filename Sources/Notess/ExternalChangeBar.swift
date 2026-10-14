import NotessCore
import SwiftUI

/// Shown above the editor when the note's file changed or vanished outside
/// Notess while the tab could not simply reload (ADR 0003).
struct ExternalChangeBar: View {
    let document: NoteDocument
    let onReload: () -> Void
    let onSave: () -> Void
    let onClose: () -> Void

    var body: some View {
        if let change = document.externalChange {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .accessibilityHidden(true)
                    content(for: change)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.yellow.opacity(0.12))
                Divider()
            }
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func content(for change: NoteDocument.ExternalChange) -> some View {
        switch change {
        case .modified:
            Text("Soubor byl změněn mimo Notess.")
            Spacer()
            Button("Načíst", action: onReload)
                .help("Zahodit neuložené změny a načíst verzi z disku")
            Button("Ponechat moje") { document.keepMine() }
                .help("Skrýt lištu; další ⌘S přepíše soubor na disku")
        case .deleted:
            Text("Soubor byl smazán mimo Notess. Text zůstává jen v tomto tabu.")
            Spacer()
            if !document.isReadOnly {
                Button("Uložit znovu", action: onSave)
                    .help("Znovu vytvořit soubor s textem z tabu")
            }
            Button("Zavřít tab", action: onClose)
        }
    }
}
