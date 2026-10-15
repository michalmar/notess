import Foundation
import Observation

/// What the Tags mode of the sidebar shows: the Tags of saved Daily Entries
/// and the Tag Timeline (see `GLOSSARY.md`) of the one selected Tag, both read
/// from the `SearchIndex`, so only saved content appears.
///
/// Queries run on the index actor without blocking the caller. An answer that
/// arrives after a newer selection, refresh or index was requested is dropped,
/// so a slow query never overwrites what the reader asked for last.
@MainActor
@Observable
public final class TagTimelineBrowser {
    public enum LoadState<Value: Equatable & Sendable>: Equatable, Sendable {
        case loading
        case loaded(Value)
        /// The query failed; the error's description.
        case failed(String)
    }

    /// Normalised names of the Tags in saved Daily Entries, alphabetically.
    public private(set) var tags: LoadState<[String]> = .loading
    /// The one Tag whose timeline is shown, or nil.
    public private(set) var selectedTag: String?
    /// The selected Tag's timeline; nil while no Tag is selected.
    public private(set) var timeline: LoadState<[TagTimelineDay]>?

    @ObservationIgnored private var index: SearchIndex?
    @ObservationIgnored private var tagsGeneration = 0
    @ObservationIgnored private var timelineGeneration = 0

    public init() {}

    /// Shows the content of `index` (another Vault's, or none) from now on.
    /// Forgets the selection; call `refresh()` to load.
    public func connect(_ index: SearchIndex?) {
        self.index = index
        tagsGeneration += 1
        timelineGeneration += 1
        tags = .loading
        selectedTag = nil
        timeline = nil
    }

    /// Shows the timeline of `tag` (a normalised name), or nothing for nil.
    public func select(_ tag: String?) async {
        guard tag != selectedTag || (tag != nil && timeline == nil) else { return }
        selectedTag = tag
        timeline = tag == nil ? nil : .loading
        await loadTimeline()
    }

    /// Loads the Tags and the selected timeline again, e.g. after the index
    /// changed. What is shown stays visible until the new answer arrives.
    public func refresh() async {
        async let tags: Void = loadTags()
        async let timeline: Void = loadTimeline()
        _ = await (tags, timeline)
    }

    private func loadTags() async {
        tagsGeneration += 1
        let generation = tagsGeneration
        guard let index else { return }
        let outcome = await Self.outcome { try await index.journalTags() }
        guard generation == tagsGeneration else { return }
        tags = Self.state(of: outcome)
    }

    private func loadTimeline() async {
        timelineGeneration += 1
        let generation = timelineGeneration
        guard let index, let tag = selectedTag else { return }
        let outcome = await Self.outcome { try await index.tagTimeline(for: tag) }
        guard generation == timelineGeneration else { return }
        timeline = Self.state(of: outcome)
    }

    private static func outcome<Value>(
        of query: () async throws -> Value
    ) async -> Result<Value, Error> {
        do { return .success(try await query()) } catch { return .failure(error) }
    }

    private static func state<Value>(of outcome: Result<Value, Error>) -> LoadState<Value> {
        switch outcome {
        case .success(let value): .loaded(value)
        case .failure(let error): .failed(error.localizedDescription)
        }
    }
}
