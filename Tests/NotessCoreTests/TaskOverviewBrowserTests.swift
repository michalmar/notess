import Foundation
import Testing
@testable import NotessCore

@MainActor
@Suite("Task Overview browsing")
final class TaskOverviewBrowserTests {
    private let vault: TemporaryVault
    private let databaseURL: URL

    init() throws {
        vault = try TemporaryVault()
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotessTaskBrowserTests-\(UUID().uuidString)")
            .appendingPathComponent("index.sqlite")
        try vault.write("# 2026-11-04\n\n- [ ] Otevřený\n- [x] Hotový\n", to: "Journal/2026/11/2026-11-04.md")
        try vault.write("# Plán\n\n- [ ] Z plánu\n", to: "Plán.md")
    }

    deinit {
        try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
    }

    private func makeIndex() async throws -> SearchIndex {
        let index = SearchIndex(vault: vault.vault, databaseURL: databaseURL)
        try await index.synchronize()
        return index
    }

    private func texts(_ browser: TaskOverviewBrowser) -> [String]? {
        guard case .loaded(let tasks) = browser.tasks else { return nil }
        return tasks.map(\.text)
    }

    @Test("the default list groups deadlines in urgency order, retaining the selected time filter and row across midnight")
    func calendarRollover() async throws {
        try vault.write("""
            - [ ] Včera 📅 2026-03-07
            - [ ] Dnes 📅 2026-03-08
            - [ ] Zítra 📅 2026-03-09
            - [ ] Neplatný 📅 2026-02-31
            """, to: "Plán.md")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        var now = ISO8601DateFormatter().date(from: "2026-03-08T05:00:00Z")!
        let browser = TaskOverviewBrowser(now: { now }, calendar: { calendar })
        browser.connect(try await makeIndex())
        await browser.refresh()

        #expect(browser.groups.map(\.filter) == [.overdue, .today, .upcoming, .undated])
        #expect(browser.groups.map { $0.tasks.map(\.text) } == [
            ["Včera 📅 2026-03-07"], ["Dnes 📅 2026-03-08"], ["Zítra 📅 2026-03-09"], ["Otevřený", "Neplatný 📅 2026-02-31"],
        ])
        await browser.select(.today)
        browser.selectedTaskID = "Plán.md#1"
        #expect(texts(browser) == ["Dnes 📅 2026-03-08"])

        // The spring DST day is 23 hours long, not an elapsed 24-hour window.
        now = ISO8601DateFormatter().date(from: "2026-03-09T03:59:59Z")!
        await browser.refresh()
        #expect(texts(browser) == ["Dnes 📅 2026-03-08"])
        now = ISO8601DateFormatter().date(from: "2026-03-09T04:00:00Z")!
        await browser.refresh()
        #expect(browser.filter == .today)
        #expect(texts(browser) == ["Zítra 📅 2026-03-09"])
        #expect(browser.selectedTaskID == "Plán.md#1")
        await browser.select(.overdue)
        #expect(texts(browser) == ["Včera 📅 2026-03-07", "Dnes 📅 2026-03-08"])
    }

    @Test("the same saved deadline is upcoming, today and overdue by the injected local day, including a time-zone change")
    func localDeadlineBoundaries() async throws {
        try vault.write("- [ ] Termín 📅 2026-11-01\n", to: "Plán.md")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        var now = ISO8601DateFormatter().date(from: "2026-11-01T03:59:59Z")!
        let browser = TaskOverviewBrowser(now: { now }, calendar: { calendar })
        browser.connect(try await makeIndex())
        await browser.select(.upcoming)
        #expect(texts(browser) == ["Termín 📅 2026-11-01"])
        now = ISO8601DateFormatter().date(from: "2026-11-01T04:00:00Z")!
        await browser.select(.today)
        #expect(texts(browser) == ["Termín 📅 2026-11-01"])
        // The fall DST day ends 25 hours later.
        now = ISO8601DateFormatter().date(from: "2026-11-02T04:59:59Z")!
        await browser.refresh()
        #expect(texts(browser) == ["Termín 📅 2026-11-01"])
        now = ISO8601DateFormatter().date(from: "2026-11-02T05:00:00Z")!
        await browser.select(.overdue)
        #expect(texts(browser) == ["Termín 📅 2026-11-01"])

        now = ISO8601DateFormatter().date(from: "2026-11-02T00:30:00Z")!
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        await browser.refresh()
        #expect(texts(browser) == ["Termín 📅 2026-11-01"])
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        await browser.refresh()
        #expect(texts(browser) == [])
        await browser.select(.today)
        #expect(texts(browser) == ["Termín 📅 2026-11-01"])
    }

    @Test("the Task Overview starts on all Open Tasks and switches to Completed Tasks")
    func filters() async throws {
        let browser = TaskOverviewBrowser()
        #expect(browser.filter == .open)
        #expect(browser.tasks == .loading)
        browser.connect(try await makeIndex())
        await browser.refresh()
        #expect(texts(browser) == ["Otevřený", "Z plánu"])

        await browser.select(.completed)
        #expect(browser.filter == .completed)
        #expect(texts(browser) == ["Hotový"])

        await browser.select(.open)
        #expect(texts(browser) == ["Otevřený", "Z plánu"])
    }

    @Test("refreshing keeps the filter and the remembered scroll position; switching filters starts at the top")
    func keepsReadingPosition() async throws {
        let browser = TaskOverviewBrowser()
        let index = try await makeIndex()
        browser.connect(index)
        await browser.refresh()
        browser.selectedTaskID = "Plán.md#0"

        try vault.write("# Plán\n\n- [ ] Z plánu\n- [ ] Další\n", to: "Plán.md")
        try await index.update(relativePaths: ["Plán.md"])
        await browser.refresh()
        #expect(texts(browser) == ["Otevřený", "Z plánu", "Další"])
        #expect(browser.selectedTaskID == "Plán.md#0")

        await browser.select(.completed)
        #expect(browser.selectedTaskID == nil)
    }

    @Test("only Tasks currently listed can be opened")
    func listedTasks() async throws {
        let browser = TaskOverviewBrowser()
        browser.connect(try await makeIndex())
        await browser.refresh()
        guard case .loaded(let open) = browser.tasks else { Issue.record("not loaded"); return }
        let listed = try #require(open.first)
        #expect(browser.listed(listed.id) == listed)

        await browser.select(.completed)
        #expect(browser.listed(listed.id) == nil)
    }

    @Test("connecting another index forgets the previous Vault's Tasks")
    func reconnects() async throws {
        let browser = TaskOverviewBrowser()
        browser.connect(try await makeIndex())
        await browser.select(.completed)
        browser.selectedTaskID = "x"

        let other = try TemporaryVault()
        let otherURL = databaseURL.deletingLastPathComponent().appendingPathComponent("other.sqlite")
        try other.write("# Jiný\n\n- [ ] Jinde\n", to: "Jiný.md")
        let otherIndex = SearchIndex(vault: other.vault, databaseURL: otherURL)
        try await otherIndex.synchronize()

        browser.connect(otherIndex)
        #expect(browser.tasks == .loading)
        #expect(browser.filter == .open)
        #expect(browser.selectedTaskID == nil)
        await browser.refresh()
        #expect(texts(browser) == ["Jinde"])
    }

    @Test("an older, slower answer never overwrites the Tasks of the filter selected last")
    func staleCompletionsAreIgnored() async throws {
        let browser = TaskOverviewBrowser()
        browser.connect(try await makeIndex())
        let refresh = Task { await browser.refresh() }
        await browser.select(.completed)
        await refresh.value
        #expect(browser.filter == .completed)
        #expect(texts(browser) == ["Hotový"])
    }
}
