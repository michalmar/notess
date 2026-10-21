import NotessCore
import SwiftUI

/// The Cmd+Shift+F overlay: fulltext search of saved notes, one row per
/// matching note, grouped Journal / Notes / Brain and narrowed by an All /
/// Journal / Notes / Brain scope.
/// `#tag` words in the query filter by Tag.
struct SearchView: View {
    @Bindable var search: GlobalSearch
    let isIndexing: Bool
    let revision: Int
    let open: (SearchResult) -> Void
    let dismiss: () -> Void

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Hledat v uložených poznámkách… (#tag filtruje)", text: $search.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isSearchFocused)
                    .onSubmit(openSelection)
            }
            .padding(14)

            HStack(spacing: 10) {
                Picker("Rozsah hledání", selection: $search.scope) {
                    ForEach(SearchScope.allCases, id: \.self) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .focusable(false)
                Spacer()
                Label("Jen uložené poznámky", systemImage: "internaldrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Hledání používá uložené soubory. Neuložené změny v otevřených poznámkách se v něm neprojeví, dokud je neuložíte.")
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Divider()

            content
                .frame(height: 380)
        }
        .frame(width: 640)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .shadow(radius: 16)
        // Deferred one turn: focusing during the overlay's first appearance is
        // dropped while the editor still holds first responder.
        .onAppear { DispatchQueue.main.async { isSearchFocused = true } }
        .onChange(of: revision) { _, _ in search.refresh() }
        .onMoveCommand(perform: moveSelection)
        .onExitCommand(perform: dismiss)
        .onDisappear { search.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        if search.parsedQuery.isEmpty {
            ContentUnavailableView(
                "Hledání v uložených poznámkách",
                systemImage: "text.magnifyingglass",
                description: Text("Pište slova, která má Sekce obsahovat. `#tag` omezí výsledky na Sekce s Tagem. Neuložené změny se nehledají.")
            )
        } else if let error = search.error {
            ContentUnavailableView(
                "Hledání selhalo",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if search.results.isEmpty {
            if isIndexing {
                ProgressView("Indexuji poznámky…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if search.isSearching {
                Color.clear
            } else {
                ContentUnavailableView.search(text: search.query)
            }
        } else {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    List(selection: $search.selection) {
                        ForEach(search.groups) { group in
                            Section(group.kind.searchGroupTitle) {
                                ForEach(group.results) { result in
                                    SearchResultRow(result: result)
                                        .tag(result.id)
                                        .id(result.id)
                                        .onTapGesture { open(result) }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .onChange(of: search.selection) { _, selected in
                        guard let selected else { return }
                        proxy.scrollTo(selected)
                    }
                }
                if isIndexing {
                    // Results found so far stay usable; the footer says more may come.
                    ProgressView("Indexuji poznámky… výsledky mohou být neúplné")
                        .controlSize(.small)
                        .font(.caption)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                }
            }
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        switch direction {
        case .up: search.moveSelection(by: -1)
        case .down: search.moveSelection(by: 1)
        default: break
        }
    }

    private func openSelection() {
        guard let result = search.selectedResult else { return }
        open(result)
    }
}

/// One matching note: its name and path, the first matching Section's heading
/// and a preview of the match.
private struct SearchResultRow: View {
    let result: SearchResult

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: result.kind.searchSymbol)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(result.noteName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(result.relativePath)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if result.title != nil, result.title != result.noteName || result.highlightedTitle.parts.contains(where: \.isMatch) {
                    Text(Self.attributed(result.highlightedTitle))
                        .font(.callout)
                        .lineLimit(1)
                }
                if !result.snippet.parts.isEmpty {
                    Text(Self.attributed(result.snippet))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
    }

    static func attributed(_ snippet: SearchSnippet) -> AttributedString {
        snippet.parts.reduce(into: AttributedString()) { result, part in
            var text = AttributedString(part.text)
            if part.isMatch {
                text.inlinePresentationIntent = .stronglyEmphasized
                text.foregroundColor = .primary
                text.backgroundColor = Color.accentColor.opacity(0.25)
            }
            result += text
        }
    }
}

private extension SearchScope {
    var title: String {
        switch self {
        case .all: "Vše"
        case .journal: "Journal"
        case .notes: "Notes"
        case .brain: "Brain"
        }
    }
}

private extension NoteKind {
    var searchGroupTitle: String {
        switch self {
        case .dailyEntry: "Journal"
        case .freeNote: "Notes"
        case .brainNote: "Brain"
        }
    }

    var searchSymbol: String {
        switch self {
        case .dailyEntry: "calendar"
        case .freeNote: "doc.text"
        case .brainNote: "brain"
        }
    }
}
