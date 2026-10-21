import Foundation
import NotessCore
import Observation

/// One opening of the Cmd+Shift+F global search: the query, the scope and the
/// live results. Each opening gets a fresh instance, so it starts empty and on
/// All. Searches run on the `SearchIndex` actor, off the main thread; typing
/// only schedules them.
@MainActor
@Observable
final class GlobalSearch {
    /// Delay after a keystroke before searching, so fast typing searches once.
    static let typingDebounce: Duration = .milliseconds(120)

    var query = "" {
        didSet { if query != oldValue { run(debounce: true) } }
    }
    var scope: SearchScope = .all {
        didSet {
            guard scope != oldValue else { return }
            // The previous scope's notes must not stay listed or openable meanwhile.
            groups = []
            selection = nil
            run(debounce: false)
        }
    }
    private(set) var groups: [SearchResultGroup] = []
    private(set) var error: String?
    /// A search for the current query and scope has not finished yet.
    private(set) var isSearching = false
    var selection: SearchResult.ID?

    var results: [SearchResult] { groups.flatMap(\.results) }
    var parsedQuery: SearchQuery { SearchQuery(query) }

    @ObservationIgnored let index: SearchIndex
    @ObservationIgnored private var task: Task<Void, Never>?

    init(index: SearchIndex) {
        self.index = index
    }

    /// Searches again without delay, e.g. after the index changed.
    func refresh() {
        run(debounce: false)
    }

    func cancel() {
        task?.cancel()
        task = nil
        isSearching = false
    }

    func moveSelection(by offset: Int) {
        let ids = results.map(\.id)
        guard !ids.isEmpty else { return }
        guard let current = selection.flatMap({ ids.firstIndex(of: $0) }) else {
            selection = ids.first
            return
        }
        selection = ids[min(ids.count - 1, max(0, current + offset))]
    }

    var selectedResult: SearchResult? {
        results.first { $0.id == selection } ?? results.first
    }

    private func run(debounce: Bool) {
        task?.cancel()
        let query = parsedQuery
        let scope = scope
        let index = index
        guard !query.isEmpty else {
            task = nil
            isSearching = false
            groups = []
            error = nil
            selection = nil
            return
        }
        isSearching = true
        task = Task { [weak self] in
            if debounce {
                do { try await Task.sleep(for: Self.typingDebounce) } catch { return }
            }
            let outcome: Result<[SearchResultGroup], Error>
            do {
                outcome = .success(try await index.search(query, scope: scope))
            } catch {
                outcome = .failure(error)
            }
            guard !Task.isCancelled, let self else { return }
            self.apply(outcome)
        }
    }

    private func apply(_ outcome: Result<[SearchResultGroup], Error>) {
        isSearching = false
        switch outcome {
        case .success(let found):
            error = nil
            groups = found
        case .failure(let failure):
            error = failure.localizedDescription
            groups = []
        }
        if selection.map({ id in !results.contains { $0.id == id } }) ?? true {
            selection = results.first?.id
        }
    }
}
