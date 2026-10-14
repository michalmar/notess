import AppKit
import NotessCore
import NotessEditor
import SwiftUI

struct NoteEditorScreen: View {
    let document: NoteDocument
    @Bindable var settings: AppSettings
    var reveal: EditorReveal?
    var onOpenWikiLink: (WikiLink) -> Void = { _ in }

    var body: some View {
        MarkdownEditor(
            documentID: document.id,
            initialText: { document.text },
            fontName: settings.editorFont.name,
            fontSize: CGFloat(settings.editorFont.size),
            reveal: reveal,
            onOpenWikiLink: onOpenWikiLink,
            isEditable: !document.isReadOnly,
            onTextChange: { document.text = $0 }
        )
        .navigationTitle(document.displayName)
        .navigationSubtitle(document.hasUnsavedChanges ? "Neuloženo" : "")
        .toolbar {
            ToolbarItem(placement: .status) {
                UnsavedChangesIndicator(isVisible: document.hasUnsavedChanges)
            }
        }
        .background(WindowDocumentEditedMarker(isEdited: document.hasUnsavedChanges))
    }
}

/// A dot shown while the note has unsaved changes (ADR 0003).
struct UnsavedChangesIndicator: View {
    let isVisible: Bool

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 8))
            .foregroundStyle(.secondary)
            .opacity(isVisible ? 1 : 0)
            .help(isVisible ? "Neuložené změny – uložte pomocí ⌘S" : "Uloženo")
            .accessibilityLabel(isVisible ? "Neuložené změny" : "Uloženo")
    }
}

/// Mirrors unsaved changes into the window's standard "edited" dot in the close button.
private struct WindowDocumentEditedMarker: NSViewRepresentable {
    let isEdited: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { view.window?.isDocumentEdited = isEdited }
    }
}
