import NotessCore
import SwiftUI

struct NoteTabBar: View {
    @Bindable var session: TabSession
    let onSelect: (NoteDocument.ID) -> Void
    let onClose: (NoteDocument.ID) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(session.documents) { document in
                    NoteTab(
                        document: document,
                        isActive: session.activeDocument?.id == document.id,
                        onSelect: { onSelect(document.id) },
                        onClose: { onClose(document.id) }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .background(.bar)
    }
}

private struct NoteTab: View {
    @Bindable var document: NoteDocument
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    if document.externalChange != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.yellow)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .opacity(document.hasUnsavedChanges ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                    Text(document.displayName)
                        .strikethrough(document.externalChange == .deleted)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Zavřít \(document.displayName)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .help(helpText)
    }

    private var accessibilityLabel: String {
        var parts = [document.displayName]
        if let status = statusText { parts.append(status) }
        if document.hasUnsavedChanges { parts.append("neuložené změny") }
        return parts.joined(separator: ", ")
    }

    private var helpText: String {
        let path = document.fileURL.path(percentEncoded: false)
        return statusText.map { "\(path)\n\($0)" } ?? path
    }

    private var statusText: String? {
        switch document.externalChange {
        case .deleted: "smazáno mimo Notess"
        case .modified: "změněno mimo Notess"
        case nil: nil
        }
    }
}
