import AppKit
import NotessCore
import NotessEditor
import SwiftUI

struct NoteEditorScreen: View {
    let document: NoteDocument
    @Bindable var settings: AppSettings
    var reveal: EditorReveal?
    var backlinks: [Backlink] = []
    var onOpenWikiLink: (WikiLink) -> Void = { _ in }
    var onOpenBacklink: (Backlink) -> Void = { _ in }
    var onPasteImageFailure: (Error) -> Void = { _ in }
    var onOpenImagePreview: (ImagePreviewContent) -> Void = { _ in }
    var onImageLoadFailure: (String) -> Void = { _ in }
    var isImagePreviewPresented = false

    var body: some View {
        // A new revision means the text was reloaded from disk, so the editor reloads too.
        let contentID = EditorContentID(document: document.id, revision: document.revision)
        VStack(spacing: 0) {
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
                isInteractionEnabled: !isImagePreviewPresented,
                noteURL: document.fileURL,
                onPasteImage: { data, fileExtension in
                    document.stageAttachment(data: data, fileExtension: fileExtension).markdown
                },
                onPasteImageFailure: onPasteImageFailure,
                inlineImageData: { document.stagedAttachmentData(relativePath: $0) },
                onOpenImagePreview: onOpenImagePreview,
                onImageLoadFailure: onImageLoadFailure,
                onTextChange: { document.text = $0 }
            )
            BacklinksBar(backlinks: backlinks, onOpen: onOpenBacklink)
                .id(document.id)
        }
        .navigationTitle(document.displayName)
        .navigationSubtitle(document.hasUnsavedChanges ? "Neuloženo" : "")
        .toolbar {
            if document.isReadOnly {
                ToolbarItem(placement: .status) {
                    Label("Jen pro čtení", systemImage: "lock.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                        .help("Brain Note spravuje Agent – nelze ji upravit")
                }
            }
            ToolbarItem(placement: .status) {
                UnsavedChangesIndicator(isVisible: document.hasUnsavedChanges)
            }
        }
        .background(WindowDocumentEditedMarker(isEdited: document.hasUnsavedChanges))
    }
}

private struct BacklinksBar: View {
    let backlinks: [Backlink]
    let onOpen: (Backlink) -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text("Odkazuje sem")
                        .font(.headline)
                    Text(backlinks.count, format: .number)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Odkazuje sem, \(backlinks.count)")
            .accessibilityValue(isExpanded ? "Rozbaleno" : "Sbaleno")

            if isExpanded {
                if backlinks.isEmpty {
                    Text("Na tuto poznámku zatím nic neodkazuje.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 12)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(backlinks) { backlink in
                                Button {
                                    onOpen(backlink)
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 4) {
                                            Text(backlink.sourceDisplayName)
                                                .fontWeight(.semibold)
                                            if let section = backlink.sectionTitle {
                                                Text("› \(section)")
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Text(backlink.preview)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Otevře zdrojovou poznámku a Sekci")
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                    }
                    .frame(maxHeight: 180)
                }
            }
        }
        .background(.bar)
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
