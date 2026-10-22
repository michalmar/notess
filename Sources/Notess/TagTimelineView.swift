import NotessCore
import NotessEditor
import SwiftUI

/// Tags mode of the sidebar: Tag Groups, the Ungrouped Tags and All Tags, the
/// Tags of saved Daily Entries; one Tag is selected at a time.
struct TagList: View {
    let model: AppModel
    /// The clicked row; a Tag can have several rows (in groups, Ungrouped and All Tags).
    @State private var selectedRow: TagRow?
    @State private var newGroupRequest: NewGroupRequest?
    @State private var newGroupName = ""
    @State private var groupPendingDeletion: TagSidebar.Group?

    private var browser: TagTimelineBrowser { model.tagTimeline }

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            HStack {
                Button {
                    requestNewGroup(for: nil)
                } label: {
                    Label("Nová skupina", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("Vytvoří skupinu Tagů; Tagy, poznámky ani soubory se nezmění")
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .alert(
            newGroupRequest?.tag.map { "Nová skupina s Tagem #\($0)" } ?? "Nová skupina Tagů",
            isPresented: Binding(
                get: { newGroupRequest != nil },
                set: { if !$0 { newGroupRequest = nil } }
            ),
            presenting: newGroupRequest
        ) { request in
            TextField("Název skupiny", text: $newGroupName)
            Button("Vytvořit") { createGroup(for: request) }
            Button("Zrušit", role: .cancel) {}
        } message: { _ in
            Text("Skupina jen třídí Tagy v postranním panelu; poznámky se nezmění.")
        }
        .confirmationDialog(
            groupPendingDeletion.map { "Smazat skupinu „\($0.name)“?" } ?? "",
            isPresented: Binding(
                get: { groupPendingDeletion != nil },
                set: { if !$0 { groupPendingDeletion = nil } }
            ),
            presenting: groupPendingDeletion
        ) { group in
            Button("Smazat skupinu", role: .destructive) {
                model.deleteTagGroup(group.id)
            }
        } message: { _ in
            Text("Tagy, ostatní skupiny ani poznámky se nezmění.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch browser.tags {
        case .loading:
            ProgressView(model.isIndexing ? indexingLabel : "Načítám Tagy…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView(
                "Tagy se nepodařilo načíst",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .loaded(let tags) where tags.isEmpty && model.tagGroups.groups.isEmpty:
            EmptyIndexedContent(
                isIndexing: model.isIndexing,
                indexFailure: model.searchIndexFailure,
                title: "Žádné Tagy",
                description: "Uložené záznamy v Journalu zatím nemají žádný Tag."
            )
        case .loaded:
            if let sidebar = model.tagSidebar {
                list(sidebar)
            }
        }
    }

    private func list(_ sidebar: TagSidebar) -> some View {
        List(selection: selection) {
            if !sidebar.groups.isEmpty {
                Section("Skupiny") {
                    ForEach(sidebar.groups) { group in
                        DisclosureGroup(isExpanded: Binding(
                            get: { group.isExpanded },
                            set: { model.setTagGroup(group.id, isExpanded: $0) }
                        )) {
                            if group.tags.isEmpty {
                                Text("Žádné Tagy")
                                    .foregroundStyle(.secondary)
                                    .selectionDisabled()
                            }
                            ForEach(group.tags, id: \.self) { tag in
                                tagRow(tag, in: .group(group.id))
                            }
                        } label: {
                            Label(group.name, systemImage: "rectangle.stack")
                                .contextMenu {
                                    Button("Smazat skupinu…", role: .destructive) {
                                        groupPendingDeletion = group
                                    }
                                }
                        }
                    }
                }
            }
            if !sidebar.groups.isEmpty {
                Section("Nezařazené") {
                    if sidebar.ungroupedTags.isEmpty {
                        Text("Žádné nezařazené Tagy")
                            .foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
                    ForEach(sidebar.ungroupedTags, id: \.self) { tag in
                        tagRow(tag, in: .ungrouped)
                    }
                }
            }
            Section("Všechny Tagy") {
                if sidebar.allTags.isEmpty {
                    Text("Uložené záznamy v Journalu zatím nemají žádný Tag.")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
                ForEach(sidebar.allTags, id: \.self) { tag in
                    tagRow(tag, in: .allTags)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            IndexStatusFooter(isIndexing: model.isIndexing, indexFailure: model.searchIndexFailure)
        }
    }

    private func tagRow(_ tag: String, in location: TagRow.Location) -> some View {
        Label(tag, systemImage: "number")
            .tag(TagRow(location: location, tag: tag))
            .contextMenu {
                Menu("Přidat do skupiny") {
                    ForEach(model.tagGroups.groups) { candidate in
                        Toggle(candidate.name, isOn: Binding(
                            get: { candidate.tags.contains(tag) },
                            set: { isMember in
                                if isMember {
                                    model.addTag(tag, toGroup: candidate.id)
                                } else {
                                    model.removeTag(tag, fromGroup: candidate.id)
                                }
                            }
                        ))
                    }
                    if !model.tagGroups.groups.isEmpty { Divider() }
                    Button("Nová skupina…") { requestNewGroup(for: tag) }
                }
                if case .group(let id) = location,
                   let group = model.tagGroups.groups.first(where: { $0.id == id }) {
                    Button("Odebrat ze skupiny „\(group.name)“") {
                        model.removeTag(tag, fromGroup: id)
                    }
                }
            }
    }

    /// The clicked row while it still shows the selected Tag; otherwise the
    /// Tag's All Tags row, e.g. after the selection changed elsewhere or the
    /// Tag left the clicked group or the Ungrouped Tags.
    private var selection: Binding<TagRow?> {
        Binding(
            get: {
                guard let tag = browser.selectedTag else { return nil }
                if let selectedRow, selectedRow.tag == tag, isShown(selectedRow) { return selectedRow }
                return TagRow(location: .allTags, tag: tag)
            },
            set: { row in
                guard let row else { return }
                selectedRow = row
                model.selectTimelineTag(row.tag)
            }
        )
    }

    private func isShown(_ row: TagRow) -> Bool {
        switch row.location {
        case .allTags:
            return true
        case .ungrouped:
            return !model.tagGroups.groups.isEmpty && (model.tagSidebar?.ungroupedTags.contains(row.tag) ?? false)
        case .group(let id):
            return model.tagSidebar?.groups.contains { $0.id == id && $0.tags.contains(row.tag) } ?? false
        }
    }

    private func requestNewGroup(for tag: String?) {
        newGroupName = ""
        newGroupRequest = NewGroupRequest(tag: tag)
    }

    private func createGroup(for request: NewGroupRequest) {
        if let tag = request.tag {
            model.addTagToNewGroup(tag, named: newGroupName)
        } else {
            model.createTagGroup(named: newGroupName)
        }
    }
}

/// One row of the Tag list: a Tag in a group, in the Ungrouped Tags or in All Tags.
private struct TagRow: Hashable {
    enum Location: Hashable {
        case group(TagGroup.ID)
        case ungrouped
        case allTags
    }

    let location: Location
    let tag: String
}

/// "Nová skupina": for a Tag's context menu the new group gets that Tag.
private struct NewGroupRequest {
    let tag: String?
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
