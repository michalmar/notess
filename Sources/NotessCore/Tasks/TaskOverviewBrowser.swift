import Foundation
import Observation

/// What the Tasks mode (Úkoly) shows: the Task Overview (see `GLOSSARY.md`)
/// of one filter, read from the `SearchIndex`, so only saved content appears.
/// Browsing never changes a note.
///
/// Queries run on the index actor without blocking the caller. An answer that
/// arrives after a newer filter, refresh or index was requested is dropped.
@MainActor
@Observable
public final class TaskOverviewBrowser {
    public typealias LoadState = TagTimelineBrowser.LoadState

    /// The selected filter; Všechny nesplněné (`.open`) until the reader picks another.
    public private(set) var filter: TaskFilter = .open
    /// The Tasks the selected filter lists, in source order.
    public private(set) var tasks: LoadState<[TaskOccurrence]> = .loading
    /// The selected Task row, kept while the reader opens its note and comes
    /// back, so the list returns to it; a new filter starts at the top.
    public var selectedTaskID: TaskOccurrence.ID?

    @ObservationIgnored private var index: SearchIndex?
    @ObservationIgnored private var generation = 0

    public init() {}

    /// Shows the Tasks of `index` (another Vault's, or none) from now on.
    /// Starts over on Open Tasks at the top; call `refresh()` to load.
    public func connect(_ index: SearchIndex?) {
        self.index = index
        generation += 1
        filter = .open
        tasks = .loading
        selectedTaskID = nil
    }

    /// Lists the Tasks `filter` selects.
    public func select(_ filter: TaskFilter) async {
        guard filter != self.filter else { return }
        self.filter = filter
        tasks = .loading
        selectedTaskID = nil
        await refresh()
    }

    /// Loads the selected filter's Tasks again, e.g. after the index changed.
    /// What is shown stays visible until the new answer arrives.
    public func refresh() async {
        generation += 1
        let generation = generation
        guard let index else { return }
        let filter = filter
        let outcome: Result<[TaskOccurrence], Error>
        do { outcome = .success(try await index.tasks(filter)) } catch { outcome = .failure(error) }
        guard generation == self.generation else { return }
        switch outcome {
        case .success(let value): tasks = .loaded(value)
        case .failure(let error): tasks = .failed(error.localizedDescription)
        }
    }

    /// The listed Task with `id`, or nil when the current list does not show it.
    public func listed(_ id: TaskOccurrence.ID) -> TaskOccurrence? {
        guard case .loaded(let tasks) = tasks else { return nil }
        return tasks.first { $0.id == id }
    }
}
