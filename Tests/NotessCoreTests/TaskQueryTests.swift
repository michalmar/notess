import Foundation
import Testing
@testable import NotessCore

@Suite("Task queries over saved notes")
final class TaskQueryTests {
    private let vault: TemporaryVault
    private let databaseURL: URL

    init() throws {
        vault = try TemporaryVault()
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotessTaskTests-\(UUID().uuidString)")
            .appendingPathComponent("index.sqlite")
    }

    deinit {
        try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
    }

    private func makeIndex() -> SearchIndex {
        SearchIndex(vault: vault.vault, databaseURL: databaseURL)
    }

    private func texts(_ tasks: [TaskOccurrence]) -> [String] {
        tasks.map(\.text)
    }

    @Test("open Tasks come from saved Daily Entries newest first, then Free Notes in any folder by name, never Brain Notes")
    func openTasksAcrossTheVault() async throws {
        try vault.write("# 2026-11-03\n\n- [ ] Starší\n", to: "Journal/2026/11/2026-11-03.md")
        try vault.write("# 2026-11-04\n\n- [ ] Novější první\n- [ ] Novější druhý\n", to: "Journal/2026/11/2026-11-04.md")
        try vault.write("# Zeta\n\n- [ ] Ze Zety\n", to: "Zeta.md")
        try vault.write("# Alfa\n\n- [ ] Z Alfy\n", to: "Projekty/Klienti/Alfa.md")
        try vault.write("# Acme\n\n- [ ] Z mozku\n", to: "_brain/companies/Acme.md")
        let index = makeIndex()
        try await index.synchronize()

        let tasks = try await index.tasks(.open)

        #expect(texts(tasks) == ["Novější první", "Novější druhý", "Starší", "Z Alfy", "Ze Zety"])
        #expect(tasks.map(\.source) == [
            .dailyEntry(Day(year: 2026, month: 11, day: 4)),
            .dailyEntry(Day(year: 2026, month: 11, day: 4)),
            .dailyEntry(Day(year: 2026, month: 11, day: 3)),
            .freeNote(name: "Alfa", folder: "Projekty/Klienti"),
            .freeNote(name: "Zeta", folder: ""),
        ])
        #expect(tasks.allSatisfy { !$0.isCompleted })
        #expect(Set(tasks.map(\.id)).count == tasks.count)
    }

    @Test("every list marker makes a Task; [x] and [X] are completed and listed only by the Completed filter")
    func listMarkersAndCompletion() async throws {
        try vault.write("""
            # Značky

            - [ ] pomlčka
            * [ ] hvězdička
            + [x] plus hotovo
            1. [X] číslo hotovo
            2) [ ] závorka
            """, to: "Značky.md")
        let index = makeIndex()
        try await index.synchronize()

        #expect(texts(try await index.tasks(.open)) == ["pomlčka", "hvězdička", "závorka"])
        let completed = try await index.tasks(.completed)
        #expect(texts(completed) == ["plus hotovo", "číslo hotovo"])
        #expect(completed.allSatisfy { $0.isCompleted })
    }

    @Test("checkbox-like text in prose, on lines without a list marker and in code is not a Task")
    func notTasks() async throws {
        try vault.write("""
            # Jinde

            Odstavec s [ ] uvnitř věty.
            [ ] holý řádek
            [x] holý hotový

            ```
            - [ ] v kódu
            ```

                - [ ] odsazený kód

            - [ ] skutečný
            """, to: "Jinde.md")
        let index = makeIndex()
        try await index.synchronize()

        #expect(texts(try await index.tasks(.open)) == ["skutečný"])
        #expect(texts(try await index.tasks(.completed)) == [])
    }

    @Test("equal Task text stays separate occurrences, and nested Tasks keep their own status")
    func duplicatesAndNesting() async throws {
        try vault.write("""
            # Den

            - [ ] Zavolat
            - [ ] Zavolat
            - [x] Rodič hotový
              - [ ] Dítě otevřené
            """, to: "Journal/2026/11/2026-11-05.md")
        try vault.write("# Jiná\n\n- [ ] Zavolat\n", to: "Jiná.md")
        let index = makeIndex()
        try await index.synchronize()

        let open = try await index.tasks(.open)
        #expect(texts(open) == ["Zavolat", "Zavolat", "Dítě otevřené", "Zavolat"])
        #expect(Set(open.map(\.id)).count == 4)
        #expect(texts(try await index.tasks(.completed)) == ["Rodič hotový"])
    }

    @Test("Free Notes with the same name in different folders are told apart by their folder")
    func sameNamedFreeNotes() async throws {
        try vault.write("# Plán\n\n- [ ] Z kořene\n", to: "Plán.md")
        try vault.write("# Plán\n\n- [ ] Z projektu\n", to: "Projekty/Plán.md")
        let index = makeIndex()
        try await index.synchronize()

        let tasks = try await index.tasks(.open)
        #expect(tasks.map(\.source) == [.freeNote(name: "Plán", folder: ""), .freeNote(name: "Plán", folder: "Projekty")])
        #expect(texts(tasks) == ["Z kořene", "Z projektu"])
    }

    @Test("a changed, completed or deleted note updates its Tasks; nothing else is rewritten")
    func updatesFollowSavedFiles() async throws {
        try vault.write("# A\n\n- [ ] První\n- [ ] Druhý\n", to: "A.md")
        try vault.write("# B\n\n- [ ] Z béčka\n", to: "B.md")
        let index = makeIndex()
        try await index.synchronize()
        let untouched = try vault.read("B.md")

        try vault.write("# A\n\n- [x] První\n- [ ] Druhý\n- [ ] Třetí\n", to: "A.md")
        try await index.update(relativePaths: ["A.md"])
        #expect(texts(try await index.tasks(.open)) == ["Druhý", "Třetí", "Z béčka"])
        #expect(texts(try await index.tasks(.completed)) == ["První"])

        try FileManager.default.removeItem(at: vault.vault.rootURL.appendingPathComponent("A.md"))
        try await index.update(relativePaths: ["A.md"])
        #expect(texts(try await index.tasks(.open)) == ["Z béčka"])
        #expect(texts(try await index.tasks(.completed)) == [])
        #expect(try vault.read("B.md") == untouched)
    }

    @Test("reopening the index and rebuilding it reproduce the same Tasks")
    func reopenAndRebuild() async throws {
        try vault.write("# 2026-11-06\n\n- [ ] Ráno\n- [x] Hotovo\n", to: "Journal/2026/11/2026-11-06.md")
        try vault.write("# Seznam\n\n- [ ] Koupit\n", to: "Seznam.md")
        let first = makeIndex()
        try await first.synchronize()
        let open = try await first.tasks(.open)
        let completed = try await first.tasks(.completed)

        let reopened = makeIndex()
        try await reopened.synchronize()
        #expect(try await reopened.tasks(.open) == open)
        #expect(try await reopened.tasks(.completed) == completed)

        try await reopened.rebuild()
        #expect(try await reopened.tasks(.open) == open)
        #expect(try await reopened.tasks(.completed) == completed)
    }

    @Test("a Task is located in the note's current text only while it is still at its saved place")
    func locatingATask() async throws {
        let saved = "# Úkoly\n\n- [ ] První\n- [ ] Druhý\n"
        try vault.write(saved, to: "Úkoly.md")
        let index = makeIndex()
        try await index.synchronize()
        let second = try #require(try await index.tasks(.open).last)

        let box = try #require(second.range(in: saved))
        #expect((saved as NSString).substring(with: box) == "[ ]")

        // Typing after the Task (an unsaved edit) keeps it in place.
        #expect(second.range(in: saved + "Dopsáno\n") == box)
        // Text inserted before it moves it: the saved place is no longer safe.
        #expect(second.range(in: "# Úkoly\n\nÚvod\n- [ ] První\n- [ ] Druhý\n") == nil)
        // A different Task at the same place is not the listed one.
        #expect(second.range(in: "# Úkoly\n\n- [ ] První\n- [ ] Jiný\n") == nil)
        #expect(second.range(in: "") == nil)
    }
}
