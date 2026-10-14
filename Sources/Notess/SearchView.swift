import NotessCore
import SwiftUI

/// The Cmd+Shift+F overlay: fulltext search over Sections, grouped Journal /
/// Notes / Brain. `#tag` words in the query filter by Tag.
struct SearchView: View {
    let index: SearchIndex
    let isIndexing: Bool
    let open: (SearchResult) -> Void
    let dismiss: () -> Void

    @State private var query = ""
    @State private var groups: [SearchResultGroup] = []
    @State private var selection: SearchResult.ID?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool

    private var results: [SearchResult] { groups.flatMap(\.results) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Hledat v poznámkách… (#tag filtruje)", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isSearchFocused)
                    .onSubmit(openSelection)
                if isIndexing {
                    ProgressView()
                        .controlSize(.small)
                        .help("Index hledání se aktualizuje")
                }
            }
            .padding(14)

            Divider()

            content
                .frame(height: 380)
        }
        .frame(width: 640)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .shadow(radius: 16)
        .onAppear { isSearchFocused = true }
        .onChange(of: query) { _, _ in runSearch(debounce: true) }
        .onChange(of: isIndexing) { _, _ in runSearch(debounce: false) }
        .onMoveCommand(perform: moveSelection)
        .onExitCommand(perform: dismiss)
        .onDisappear { searchTask?.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        if SearchQuery(query).isEmpty {
            ContentUnavailableView(
                "Hledání v Sekcích",
                systemImage: "text.magnifyingglass",
                description: Text("Pište slova, která má Sekce obsahovat. `#tag` omezí výsledky na Sekce s Tagem.")
            )
        } else if results.isEmpty {
            if isIndexing {
                ProgressView("Indexuji poznámky…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView.search(text: query)
            }
        } else {
            ScrollViewReader { proxy in
                List(selection: $selection) {
                    ForEach(groups) { group in
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
                .onChange(of: selection) { _, selected in
                    guard let selected else { return }
                    proxy.scrollTo(selected)
                }
            }
        }
    }

    private func runSearch(debounce: Bool) {
        searchTask?.cancel()
        let query = SearchQuery(query)
        searchTask = Task {
            if debounce {
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            }
            let found = (try? await index.search(query)) ?? []
            guard !Task.isCancelled else { return }
            groups = found
            if selection.map({ id in !found.contains { $0.results.contains { $0.id == id } } }) ?? true {
                selection = found.first?.results.first?.id
            }
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let ids = results.map(\.id)
        guard !ids.isEmpty else { return }
        guard let current = selection.flatMap({ ids.firstIndex(of: $0) }) else {
            selection = ids.first
            return
        }
        switch direction {
        case .up: selection = ids[max(0, current - 1)]
        case .down: selection = ids[min(ids.count - 1, current + 1)]
        default: break
        }
    }

    private func openSelection() {
        guard let result = results.first(where: { $0.id == selection }) ?? results.first else { return }
        open(result)
    }
}

private struct SearchResultRow: View {
    let result: SearchResult

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: result.kind.searchSymbol)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    if result.title != nil {
                        Text(Self.attributed(result.highlightedTitle))
                            .lineLimit(1)
                    } else {
                        Text(result.noteName)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(result.title == nil ? result.relativePath : result.noteName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
