import NotessCore
import NotessEditor
import SwiftUI

/// Tags mode of the sidebar: the Tags of saved Daily Entries; one is selected at a time.
struct TagList: View {
    let browser: TagTimelineBrowser
    let isIndexing: Bool
    let indexFailure: String?
    let select: (String?) -> Void

    var body: some View {
        switch browser.tags {
        case .loading:
            ProgressView(isIndexing ? indexingLabel : "Načítám Tagy…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView(
                "Tagy se nepodařilo načíst",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .loaded(let tags) where tags.isEmpty:
            EmptyIndexedContent(
                isIndexing: isIndexing,
                indexFailure: indexFailure,
                title: "Žádné Tagy",
                description: "Uložené záznamy v Journalu zatím nemají žádný Tag."
            )
        case .loaded(let tags):
            List(selection: Binding(
                get: { browser.selectedTag },
                set: { tag in if let tag { select(tag) } }
            )) {
                ForEach(tags, id: \.self) { tag in
                    Label(tag, systemImage: "number")
                        .tag(tag)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                IndexStatusFooter(isIndexing: isIndexing, indexFailure: indexFailure)
            }
        }
    }
}

/// Tags mode detail: the selected Tag's Tag Timeline (see `GLOSSARY.md`), read-only.
struct TagTimelineView: View {
    let browser: TagTimelineBrowser
    @Bindable var settings: AppSettings
    let isIndexing: Bool
    let indexFailure: String?
    let noteURL: (TagTimelineSection) -> URL?
    let openImagePreview: (ImagePreviewContent) -> Void
    let open: (TagTimelineSection) -> Void

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(browser.selectedTag.map { "#\($0)" } ?? "Tagy")
            .navigationSubtitle("")
    }

    @ViewBuilder
    private var content: some View {
        if let tag = browser.selectedTag, let timeline = browser.timeline {
            switch timeline {
            case .loading:
                ProgressView("Načítám časovou osu…")
            case .failed(let message):
                ContentUnavailableView(
                    "Časovou osu se nepodařilo načíst",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            case .loaded(let days) where days.isEmpty:
                EmptyIndexedContent(
                    isIndexing: isIndexing,
                    indexFailure: indexFailure,
                    title: "Žádné uložené Sekce",
                    description: "Žádná uložená Sekce v Journalu nemá Tag #\(tag)."
                )
            case .loaded(let days):
                timelineList(days)
                    .safeAreaInset(edge: .bottom) {
                        IndexStatusFooter(isIndexing: isIndexing, indexFailure: indexFailure)
                    }
            }
        } else {
            ContentUnavailableView(
                "Vyberte Tag",
                systemImage: "number",
                description: Text("Časová osa ukáže všechny uložené Sekce s Tagem, od nejnovějšího dne.")
            )
        }
    }

    private func timelineList(_ days: [TagTimelineDay]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(days) { day in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(day.day.isoString)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        ForEach(day.sections) { section in
                            SectionCard(
                                section: section,
                                settings: settings,
                                noteURL: noteURL(section),
                                openImagePreview: openImagePreview,
                                open: open
                            )
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

private let indexingLabel = "Indexuji poznámky…"

/// Stands in for an empty Tag list or timeline, which may be empty only
/// because indexing is still running or has failed.
private struct EmptyIndexedContent: View {
    let isIndexing: Bool
    let indexFailure: String?
    let title: String
    let description: String

    var body: some View {
        if isIndexing {
            ProgressView(indexingLabel)
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let indexFailure {
            ContentUnavailableView(
                "Index hledání není úplný",
                systemImage: "exclamationmark.triangle",
                description: Text(indexFailure)
            )
        } else {
            ContentUnavailableView(title, systemImage: "number", description: Text(description))
        }
    }
}

/// Under a non-empty Tag list or timeline, which may be incomplete while
/// indexing runs or after it failed.
private struct IndexStatusFooter: View {
    let isIndexing: Bool
    let indexFailure: String?

    var body: some View {
        if isIndexing {
            ProgressView(indexingLabel)
                .controlSize(.small)
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(.bar)
        } else if let indexFailure {
            Label("Index hledání není úplný", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(indexFailure)
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
    }
}

private struct SectionCard: View {
    let section: TagTimelineSection
    @Bindable var settings: AppSettings
    let noteURL: URL?
    let openImagePreview: (ImagePreviewContent) -> Void
    let open: (TagTimelineSection) -> Void
    @State private var imageFailures: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ReadOnlyMarkdownView(
                markdown: section.markdown,
                fontName: settings.editorFont.name,
                fontSize: CGFloat(settings.editorFont.size),
                noteURL: noteURL,
                onOpenImagePreview: openImagePreview,
                onImageLoadFailure: { message in
                    if !imageFailures.contains(message) { imageFailures.append(message) }
                }
            )
            ForEach(imageFailures, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button {
                    open(section)
                } label: {
                    Label("Otevřít v Journalu", systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(.link)
                .help("Otevře záznam k úpravám a ukáže tuto Sekci")
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
        .onChange(of: section.markdown) { imageFailures = [] }
        .onChange(of: noteURL) { imageFailures = [] }
    }
}
