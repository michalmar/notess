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
        // A new revision means the text was reloaded from disk, so the editor reloads too.
        let contentID = EditorContentID(document: document.id, revision: document.revision)
        MarkdownEditor(
            documentID: contentID,
            initialText: { document.text },
            fontName: settings.editorFont.name,
            fontSize: CGFloat(settings.editorFont.size),
            reveal: reveal.flatMap { reveal in
                reveal.documentID == AnyHashable(document.id)
                    ? EditorReveal(id: reveal.id, documentID: contentID, range: reveal.range)
                    : nil
            },
            onOpenWikiLink: onOpenWikiLink,
            isEditable: !document.isReadOnly,
            noteURL: document.fileURL,
            onPasteImage: { data, fileExtension in
                document.stageAttachment(data: data, fileExtension: fileExtension).markdown
            },
            inlineImageData: { document.stagedAttachmentData(relativePath: $0) },
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

private struct EditorContentID: Hashable {
    let document: NoteDocument.ID
    let revision: Int
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
