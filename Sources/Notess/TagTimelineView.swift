import NotessCore
import NotessEditor
import SwiftUI

/// Tags mode of the sidebar: the Tags of saved Daily Entries; one is selected at a time.
struct TagList: View {
    let browser: TagTimelineBrowser
    let isIndexing: Bool
    let select: (String?) -> Void

    var body: some View {
        switch browser.tags {
        case .loading:
            ProgressView(isIndexing ? "Indexuji poznámky…" : "Načítám Tagy…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView(
                "Tagy se nepodařilo načíst",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .loaded(let tags) where tags.isEmpty:
            if isIndexing {
                ProgressView("Indexuji poznámky…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Žádné Tagy",
                    systemImage: "number",
                    description: Text("Uložené záznamy v Journalu zatím nemají žádný Tag.")
                )
            }
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
                if isIndexing {
                    ProgressView("Indexuji poznámky…")
                        .controlSize(.small)
                        .padding(8)
                }
            }
        }
    }
}

/// Tags mode detail: the selected Tag's Tag Timeline (see `GLOSSARY.md`), read-only.
struct TagTimelineView: View {
    let browser: TagTimelineBrowser
    @Bindable var settings: AppSettings
    let isIndexing: Bool
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
                if isIndexing {
                    ProgressView("Indexuji poznámky…")
                } else {
                    ContentUnavailableView(
                        "Žádné uložené Sekce",
                        systemImage: "number",
                        description: Text("Žádná uložená Sekce v Journalu nemá Tag #\(tag).")
                    )
                }
            case .loaded(let days):
                timelineList(days)
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
                            SectionCard(section: section, settings: settings, open: open)
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

private struct SectionCard: View {
    let section: TagTimelineSection
    @Bindable var settings: AppSettings
    let open: (TagTimelineSection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ReadOnlyMarkdownView(
                markdown: section.markdown,
                fontName: settings.editorFont.name,
                fontSize: CGFloat(settings.editorFont.size)
            )
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
    }
}
