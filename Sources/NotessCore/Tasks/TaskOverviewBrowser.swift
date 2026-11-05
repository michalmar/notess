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
    /// The Tasks the selected filter lists, in deadline/source order.
    public private(set) var tasks: LoadState<[TaskOccurrence]> = .loading
    /// The local day used for the last loaded projection and its groups.
    public private(set) var today: Day
    public struct Group: Identifiable, Equatable, Sendable {
        public let filter: TaskFilter
        public let tasks: [TaskOccurrence]
        public var id: TaskFilter { filter }
    }

    /// Only the default filter groups by urgency; other filters have one group.
    /// Empty groups are omitted without turning query failures into empty data.
    public var groups: [Group] {
        guard case .loaded(let tasks) = tasks else { return [] }
        let filters: [TaskFilter] = filter == .open ? [.overdue, .today, .upcoming, .undated] : [filter]
        return filters.compactMap { filter in
            let members = tasks.filter { $0.category(on: today) == filter }
            return members.isEmpty ? nil : Group(filter: filter, tasks: members)
        }
    }
    /// The selected Task row, kept independently of the presentation's scroll
    /// position while the reader opens its note; a new filter clears selection.
    public var selectedTaskID: TaskOccurrence.ID?

    @ObservationIgnored private var index: SearchIndex?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: () -> Calendar

    public init(now: @escaping () -> Date = Date.init, calendar: @escaping () -> Calendar = { .current }) {
        self.now = now
        self.calendar = calendar
        today = Self.localDay(at: now(), calendar: calendar())
    }

    private static func localDay(at date: Date, calendar: Calendar) -> Day {
        // The source form is Gregorian ISO, independent of the display calendar.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return Day(date: date, calendar: gregorian)
    }

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
        let today = Self.localDay(at: now(), calendar: calendar())
        let outcome: Result<[TaskOccurrence], Error>
        do { outcome = .success(try await index.tasks(filter, on: today)) } catch { outcome = .failure(error) }
        guard generation == self.generation else { return }
        switch outcome {
        case .success(let value):
            self.today = today
            tasks = .loaded(value)
        case .failure(let error): tasks = .failed(error.localizedDescription)
        }
    }

    /// The listed Task with `id`, or nil when the current list does not show it.
    public func listed(_ id: TaskOccurrence.ID) -> TaskOccurrence? {
        guard case .loaded(let tasks) = tasks else { return nil }
        return tasks.first { $0.id == id }
    }
}
