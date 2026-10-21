import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Notess
@testable import NotessCore

// Nested in the serialized presentation suite: hosted search windows run one
// at a time, or another one taking key status would swallow typed keys.
extension GlobalSearchPresentationTests {
/// The global search responsiveness target (#83, spec #75): first visible
/// results within 500 ms of the last keystroke, on this Mac, for an already
/// indexed Vault of 10,000 files. Measured end to end through the hosted app:
/// key events into the focused query field, the debounce, the `SearchIndex`
/// query, file grouping, result preparation and the rows of the result list.
///
/// The 10,000-file run is hardware-specific, so it runs only on request:
/// `scripts/measure-search-latency.sh` (see `docs/search-performance.md`).
@MainActor
@Suite("Global search latency", .serialized)
struct SearchLatencyTests {
    nonisolated static let target: Duration = .milliseconds(500)

    @Test("the representative Vault is reproducible and covers every kind of note")
    func representativeVault() throws {
        let counts = RepresentativeVault.Counts(dailyEntries: 300, freeNotes: 120, brainNotes: 30)
        let first = try TemporaryFolder()
        let second = try TemporaryFolder()
        try RepresentativeVault(counts: counts).write(to: first.url)
        try RepresentativeVault(counts: counts).write(to: second.url)

        let files = try first.markdownFiles()
        #expect(files.count == counts.total)
        #expect(try files == second.markdownFiles())
        for path in files {
            #expect(try first.read(path) == second.read(path), "the same seed writes the same notes")
        }
        let kinds = Dictionary(grouping: files) { NoteKind.classify(relativePath: $0) }
        #expect(kinds[.dailyEntry]?.count == counts.dailyEntries)
        #expect(kinds[.freeNote]?.count == counts.freeNotes)
        #expect(kinds[.brainNote]?.count == counts.brainNotes)
        let severalKickoffs = try files.filter { path in
            let sections = SearchSection.split(try first.read(path).precomposedStringWithCanonicalMapping)
            return sections.filter { $0.body.lowercased().contains("kickoff") }.count > 1
        }
        #expect(severalKickoffs.count > 10, "many notes have several matching Sections")
        #expect(try files.contains { try first.read(path: $0).contains("#projekty") }, "a longer Tag sharing a prefix")
    }

    @Test("a small Vault runs through the whole measurement, so the full run cannot rot")
    func smallMeasurement() async throws {
        let report = try await LatencyMeasurement(
            counts: RepresentativeVault.Counts(dailyEntries: 120, freeNotes: 60, brainNotes: 20),
            repetitions: 1
        ).run()
        #expect(report.searches.count == LatencyMeasurement.workload.count + LatencyMeasurement.scopeSwitches.count)
        #expect(report.searches.allSatisfy { $0.samples.count == 1 && $0.resultCount > 0 })
        #expect(report.indexingStatusMissing == 0, "while indexing, the open search always says so")
        print(report.markdown)
    }

    @Test(
        "10,000 files: first visible results within 500 ms of the last keystroke, typing stays responsive",
        .enabled(if: ProcessInfo.processInfo.environment["NOTESS_SEARCH_LATENCY"] == "1"),
        .timeLimit(.minutes(20))
    )
    func tenThousandFiles() async throws {
        let report = try await LatencyMeasurement(counts: RepresentativeVault.Counts(), repetitions: 5).run()
        let text = report.markdown
        print(text)
        if let path = ProcessInfo.processInfo.environment["NOTESS_SEARCH_LATENCY_REPORT"] {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        for search in report.searches {
            #expect(search.worst <= Self.target, "\(search.name): \(search.worst.milliseconds) ms")
        }
        #expect(report.warmTyping.worstStall <= .milliseconds(100), "typing during searches stays responsive")
        #expect(report.indexingTyping.worstStall <= .milliseconds(100), "typing during indexing stays responsive")
        #expect(report.indexingObserved > 0 && report.indexingStatusMissing == 0)
    }
}
}

// MARK: - Measurement

/// One end-to-end measurement run on a fresh temporary representative Vault.
@MainActor
struct LatencyMeasurement {
    struct Query {
        let name: String
        let text: String
        /// Time between keystrokes: 150 ms lets the debounce run a search for
        /// almost every prefix, so the last keystroke lands on a running search.
        let keystrokeInterval: Duration
        /// Background index work started just before the search is opened.
        var after: Trigger = .nothing
    }

    /// The index stays built, but catching up holds the `SearchIndex` actor,
    /// so a search typed right afterwards may wait for it.
    enum Trigger {
        case nothing
        /// App activation: the catch-up scan of the whole Vault.
        case activation
        /// Cmd+S on the open note: that note is read again.
        case save
    }

    static let workload: [Query] = [
        Query(name: "common word, slow typing", text: "kickoff", keystrokeInterval: .milliseconds(150)),
        Query(name: "common word, fast typing", text: "kickoff", keystrokeInterval: .milliseconds(60)),
        Query(name: "two words in one Section", text: "klient rozpočet", keystrokeInterval: .milliseconds(150)),
        Query(name: "short prefix, very many Sections", text: "ro", keystrokeInterval: .milliseconds(150)),
        Query(name: "diacritics-insensitive", text: "rozpocet", keystrokeInterval: .milliseconds(100)),
        Query(name: "rare word", text: RepresentativeVault.rareWord, keystrokeInterval: .milliseconds(150)),
        Query(name: "Tag only", text: "#projekt", keystrokeInterval: .milliseconds(150)),
        Query(name: "Tag and word", text: "#projekt kickoff", keystrokeInterval: .milliseconds(150)),
        Query(name: "right after app activation", text: "kickoff", keystrokeInterval: .milliseconds(60), after: .activation),
        Query(name: "one letter right after app activation", text: "k", keystrokeInterval: .zero, after: .activation),
        Query(name: "right after Cmd+S", text: "kickoff", keystrokeInterval: .milliseconds(60), after: .save),
    ]

    /// Clicks on the All / Journal / Notes / Brain control with `kickoff` typed.
    static let scopeSwitches: [SearchScope] = [.journal, .notes, .brain, .all]

    let counts: RepresentativeVault.Counts
    let repetitions: Int

    func run() async throws -> LatencyReport {
        let fixture = try SearchPresentationFixture()
        let vault = RepresentativeVault(counts: counts)
        let writeStart = ContinuousClock.now
        let bytes = try vault.write(to: fixture.rootURL)
        let writeTime = ContinuousClock.now - writeStart
        let opened = "Projekty/Projekt 0.md"
        let databaseURL = SearchIndex.defaultDatabaseURL(for: Vault(rootURL: fixture.rootURL))
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: databaseURL.path(percentEncoded: false) + suffix)
            }
        }

        // Initial indexing: excluded from the target, reported separately.
        let indexStart = ContinuousClock.now
        let harness = try await fixture.makeHarness(opening: opened)
        let initialIndexing = ContinuousClock.now - indexStart
        #expect(harness.model.searchIndexFailure == nil)
        let indexedFiles = try await harness.model.searchIndex?.search(SearchQuery("#projekt"), limit: .max)
            .reduce(0) { $0 + $1.results.count }
        let catchUpStart = ContinuousClock.now
        try await harness.model.searchIndex?.synchronize()
        let catchUp = ContinuousClock.now - catchUpStart

        var searches: [LatencyReport.Search] = []
        var warmTyping = TypingStats()
        for query in Self.workload {
            var samples: [Duration] = []
            var resultCount = 0
            for _ in 0..<repetitions {
                let sample = try await harness.measureTyping(query, stats: &warmTyping)
                samples.append(sample.latency)
                resultCount = sample.resultCount
            }
            let direct = try await queryOnly(query.text, scope: .all, harness: harness)
            searches.append(.init(name: "\(query.name): \(query.text)", samples: samples, resultCount: resultCount, queryOnly: direct))
        }
        for scope in Self.scopeSwitches {
            var samples: [Duration] = []
            var resultCount = 0
            for _ in 0..<repetitions {
                let sample = try await harness.measureScopeSwitch(to: scope, query: "kickoff", stats: &warmTyping)
                samples.append(sample.latency)
                resultCount = sample.resultCount
            }
            let direct = try await queryOnly("kickoff", scope: scope, harness: harness)
            searches.append(.init(name: "scope \(scope.rawValue) clicked: kickoff", samples: samples, resultCount: resultCount, queryOnly: direct))
        }

        // Typing while the whole index is rebuilt in the background.
        var indexingTyping = TypingStats()
        let rebuildStart = ContinuousClock.now
        harness.model.rebuildSearchIndex()
        let status = try await harness.typeWhileIndexing("kickoff klient", stats: &indexingTyping)
        try await harness.waitUntil { !harness.model.isIndexing }
        let rebuild = ContinuousClock.now - rebuildStart
        let search = try #require(harness.model.globalSearch)
        try await harness.waitUntil { !search.isSearching && !search.results.isEmpty }
        harness.model.isSearchPresented = false
        await harness.settle()

        return LatencyReport(
            vault: vault.summary,
            bytes: bytes,
            writeTime: writeTime,
            initialIndexing: initialIndexing,
            rebuild: rebuild,
            catchUp: catchUp,
            taggedFiles: indexedFiles ?? 0,
            searches: searches,
            warmTyping: warmTyping,
            indexingTyping: indexingTyping,
            indexingObserved: status.observed,
            indexingStatusMissing: status.missing
        )
    }

    /// Only the `SearchIndex` call, for diagnosis; not evidence of the target.
    private func queryOnly(_ text: String, scope: SearchScope, harness: SearchPresentationHarness) async throws -> Duration {
        let index = try #require(harness.model.searchIndex)
        var best = Duration.seconds(60)
        for _ in 0..<3 {
            let start = ContinuousClock.now
            _ = try await index.search(SearchQuery(text), scope: scope)
            best = min(best, ContinuousClock.now - start)
        }
        return best
    }
}

/// How the main thread kept up with typing: the longest a key event took to
/// handle and the longest the main run loop could not run (a stall).
struct TypingStats {
    var keystrokes = 0
    var worstKeystroke: Duration = .zero
    var worstStall: Duration = .zero

    @MainActor
    mutating func merge(_ heartbeat: MainThreadHeartbeat) {
        worstStall = max(worstStall, heartbeat.worstGap)
    }
}

/// Fires every few milliseconds on the main run loop and records the longest
/// gap between fires, which is how long the main thread could not respond.
@MainActor
final class MainThreadHeartbeat {
    private var timer: Timer?
    private var last = ContinuousClock.now
    private(set) var worstGap: Duration = .zero
    static let period: Duration = .milliseconds(4)

    func start() {
        last = .now
        worstGap = .zero
        let timer = Timer(timeInterval: 0.004, repeats: true) { _ in
            MainActor.assumeIsolated { self.beat() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        beat()
        timer?.invalidate()
        timer = nil
    }

    private func beat() {
        let now = ContinuousClock.now
        worstGap = max(worstGap, now - last - Self.period)
        last = now
    }
}

struct LatencyReport {
    struct Search {
        let name: String
        let samples: [Duration]
        let resultCount: Int
        let queryOnly: Duration

        var worst: Duration { samples.max() ?? .zero }
        var median: Duration { samples.sorted()[samples.count / 2] }
    }

    let vault: String
    let bytes: Int
    let writeTime: Duration
    let initialIndexing: Duration
    let rebuild: Duration
    /// A catch-up scan when nothing changed, as on app activation.
    let catchUp: Duration
    let taggedFiles: Int
    let searches: [Search]
    let warmTyping: TypingStats
    let indexingTyping: TypingStats
    /// Keystrokes typed while the index was being built, and how many of
    /// them found the open search without its indexing status.
    let indexingObserved: Int
    let indexingStatusMissing: Int

    var markdown: String {
        var lines = [
            "## Global search latency (#83)",
            "",
            "- Machine: \(MachineContext.description)",
            "- Build: \(MachineContext.configuration)",
            "- Vault: \(vault), \(bytes / 1_024) KiB, written in \(writeTime.milliseconds) ms",
            "- Initial indexing (excluded from the target): \(initialIndexing.milliseconds) ms; full rebuild with search open: \(rebuild.milliseconds) ms",
            "- Index state while measuring: built and idle (warm); \(taggedFiles) files carry #projekt",
            "- Catch-up scan with nothing changed (as on app activation): \(catchUp.milliseconds) ms",
            "- Target: first visible results ≤ \(GlobalSearchPresentationTests.SearchLatencyTests.target.milliseconds) ms after the last keystroke or scope click",
            "",
            "| Search | Results (files) | Median ms | Worst ms | Query only ms |",
            "|---|---:|---:|---:|---:|",
        ]
        for search in searches {
            lines.append("| \(search.name) | \(search.resultCount) | \(search.median.milliseconds) | \(search.worst.milliseconds) | \(search.queryOnly.milliseconds) |")
        }
        lines += [
            "",
            "- Typing during searches: \(warmTyping.keystrokes) keystrokes, worst key handling \(warmTyping.worstKeystroke.milliseconds) ms, worst main-thread stall \(warmTyping.worstStall.milliseconds) ms",
            "- Typing during the background rebuild: \(indexingTyping.keystrokes) keystrokes, worst key handling \(indexingTyping.worstKeystroke.milliseconds) ms, worst main-thread stall \(indexingTyping.worstStall.milliseconds) ms; indexing status shown at \(indexingObserved - indexingStatusMissing) of \(indexingObserved) keystrokes made while indexing",
            "",
            "Latency runs from the moment the last key event is sent to the query field until the result list shows rows for that query",
            "(debounce, `SearchIndex` query, one result per file, previews and SwiftUI list layout included). \"Query only\" is the best of three",
            "direct `SearchIndex.search` calls and is diagnostic only.",
        ]
        return lines.joined(separator: "\n")
    }
}

enum MachineContext {
    static var description: String {
        let info = ProcessInfo.processInfo
        let memory = info.physicalMemory / 1_073_741_824
        return "\(sysctl("machdep.cpu.brand_string") ?? sysctl("hw.model") ?? "unknown Mac"), "
            + "\(info.activeProcessorCount) cores, \(memory) GB, macOS \(info.operatingSystemVersionString), "
            + "\(info.isLowPowerModeEnabled ? "Low Power Mode on" : "Low Power Mode off")"
    }

    static var configuration: String {
        #if DEBUG
        "debug (`swift test`), slower than the release app"
        #else
        "release"
        #endif
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}

extension Duration {
    var milliseconds: Int {
        Int((Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15).rounded())
    }
}

// MARK: - Driving the hosted search

extension SearchPresentationHarness {
    struct Sample {
        let latency: Duration
        let resultCount: Int
    }

    /// Opens global search, types `query` key by key and returns the time from
    /// the last key event until the result list shows that query's rows.
    func measureTyping(_ query: LatencyMeasurement.Query, stats: inout TypingStats) async throws -> Sample {
        switch query.after {
        case .nothing:
            break
        case .activation:
            // What `RootView` does on `didBecomeActiveNotification`.
            model.reconcileWithDisk()
            model.synchronizeSearchIndex()
        case .save:
            #expect(model.save(), "the open note is saved")
        }
        let (search, field, baseline) = try await openSearch()
        let heartbeat = MainThreadHeartbeat()
        heartbeat.start()
        var lastKey = ContinuousClock.now
        for (offset, character) in query.text.enumerated() {
            if offset > 0 { await pump(for: query.keystrokeInterval) }
            await keepEditing(field)
            lastKey = ContinuousClock.now
            type(String(character))
            stats.keystrokes += 1
            stats.worstKeystroke = max(stats.worstKeystroke, ContinuousClock.now - lastKey)
        }
        #expect(search.query == query.text)
        let visible = try await waitForVisibleResults(of: search, query: query.text, besides: baseline)
        heartbeat.stop()
        stats.merge(heartbeat)
        let sample = Sample(latency: visible - lastKey, resultCount: search.results.count)
        model.isSearchPresented = false
        await settle()
        return sample
    }

    /// With `query` already showing results, clicks a scope segment and returns
    /// the time until that scope's results are shown.
    func measureScopeSwitch(to scope: SearchScope, query: String, stats: inout TypingStats) async throws -> Sample {
        let (search, _, baseline) = try await openSearch()
        type(query)
        _ = try await waitForVisibleResults(of: search, query: query, besides: baseline)
        if scope == .all {
            // Leave All first, so clicking All is a change.
            try clickScope(.brain)
            _ = try await waitForVisibleResults(of: search, query: query, besides: baseline)
        }
        let heartbeat = MainThreadHeartbeat()
        heartbeat.start()
        let click = ContinuousClock.now
        try clickScope(scope)
        stats.worstKeystroke = max(stats.worstKeystroke, ContinuousClock.now - click)
        #expect(search.scope == scope)
        let visible = try await waitForVisibleResults(of: search, query: query, besides: baseline)
        heartbeat.stop()
        stats.merge(heartbeat)
        #expect(search.results.allSatisfy { scope.kinds.contains($0.kind) })
        let sample = Sample(latency: visible - click, resultCount: search.results.count)
        model.isSearchPresented = false
        await settle()
        return sample
    }

    /// Opens global search while the index is rebuilt and types `text`;
    /// returns at how many keystrokes the index was still being built and at
    /// how many of those the open search did not show the indexing status.
    func typeWhileIndexing(_ text: String, stats: inout TypingStats) async throws -> (observed: Int, missing: Int) {
        let (search, field, _) = try await openSearch()
        var observed = 0
        var missing = 0
        let heartbeat = MainThreadHeartbeat()
        heartbeat.start()
        for character in text {
            await pump(for: .milliseconds(120))
            await keepEditing(field)
            let start = ContinuousClock.now
            type(String(character))
            stats.keystrokes += 1
            stats.worstKeystroke = max(stats.worstKeystroke, ContinuousClock.now - start)
            if model.isIndexing {
                observed += 1
                await pump(for: .milliseconds(20))
                if model.isIndexing, !indexingStatusIsShown { missing += 1 }
            }
        }
        heartbeat.stop()
        stats.merge(heartbeat)
        #expect(search.query == text, "every keystroke reached the query field")
        return (observed, missing)
    }

    private func openSearch() async throws -> (GlobalSearch, field: NSTextField, baseline: Set<ObjectIdentifier>) {
        let baseline = Set(tables.map(ObjectIdentifier.init))
        model.presentSearch()
        await settle()
        let field = try #require(searchField, "the query field has keyboard focus")
        return (try #require(model.globalSearch), field, baseline)
    }

    /// Other suites may host windows in parallel; when one of them takes key
    /// status, this window's query field can stop editing and keys would be
    /// lost. Restores editing with the caret at the end, outside the timed
    /// span. (Focus on opening is covered by the presentation tests.)
    private func keepEditing(_ field: NSTextField) async {
        guard searchField !== field else { return }
        window.makeFirstResponder(field)
        (window.firstResponder as? NSTextView)?.moveToEndOfDocument(nil)
    }

    /// Lets the app run between key presses: main-actor work (the debounced
    /// search and its results) and the main run loop (SwiftUI updates).
    func pump(for duration: Duration) async {
        let end = ContinuousClock.now + duration
        while ContinuousClock.now < end {
            await turn()
        }
    }

    /// One short turn of the main queue and run loop.
    private func turn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        runLoopOnce()
    }

    private func runLoopOnce() {
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
    }

    /// Spins the main run loop until the result list shows rows for `query`
    /// in the current scope and returns when that happened.
    private func waitForVisibleResults(
        of search: GlobalSearch,
        query: String,
        besides baseline: Set<ObjectIdentifier>
    ) async throws -> ContinuousClock.Instant {
        let deadline = ContinuousClock.now + .seconds(20)
        while true {
            if search.query == query, !search.isSearching, !search.results.isEmpty,
               let list = resultList(besides: baseline), list.numberOfRows == search.groups.count + search.results.count,
               list.rows(in: list.visibleRect).length > 1,
               list.rowView(atRow: 1, makeIfNecessary: false) != nil {
                list.displayIfNeeded()
                return .now
            }
            try #require(ContinuousClock.now < deadline, """
                no results for \(query): query \(search.query), searching \(search.isSearching), \
                results \(search.results.count), \
                list \(resultList(besides: baseline).map { "\($0.numberOfRows) rows" } ?? "missing")
                """)
            await turn()
        }
    }

    /// The result list of the open global search: the table that was not
    /// shown before it opened (the sidebar has tables too).
    func resultList(besides baseline: Set<ObjectIdentifier>) -> NSTableView? {
        tables.first { !baseline.contains(ObjectIdentifier($0)) }
    }

    var scopeControl: NSSegmentedControl? {
        descendants(of: hostingView).compactMap { $0 as? NSSegmentedControl }
            .first { $0.segmentCount == SearchScope.allCases.count }
    }

    /// Clicks a segment of the All / Journal / Notes / Brain control.
    func clickScope(_ scope: SearchScope) throws {
        let control = try #require(scopeControl)
        let segment = try #require(SearchScope.allCases.firstIndex(of: scope))
        control.selectedSegment = segment
        control.sendAction(control.action, to: control.target)
    }

    /// Whether the open search shows that the index is being built. SwiftUI
    /// exposes no accessibility tree without an assistive client, so this
    /// looks for the status's spinner: nothing else in the window spins.
    var indexingStatusIsShown: Bool {
        model.globalSearch != nil && descendants(of: hostingView).contains { view in
            guard let indicator = view as? NSProgressIndicator else { return false }
            return !indicator.isHiddenOrHasHiddenAncestor && indicator.window != nil
                && !indicator.visibleRect.isEmpty
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}

/// A temporary folder, deleted on deinit.
final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "NotessRepresentativeVault-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func markdownFiles() throws -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: url.path(percentEncoded: false))
        var files: [String] = []
        while let path = enumerator?.nextObject() as? String {
            if path.hasSuffix(".md") { files.append(path) }
        }
        return files.sorted()
    }

    func read(_ relativePath: String) throws -> String {
        try String(contentsOf: url.appending(path: relativePath, directoryHint: .notDirectory), encoding: .utf8)
    }

    func read(path relativePath: String) throws -> String {
        try read(relativePath)
    }
}
