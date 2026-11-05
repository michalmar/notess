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

    @Test("saved Due Dates select only Open Tasks, ordered by deadline then source, with invalid input retained")
    func dueDateFilters() async throws {
        try vault.write("""
            - [ ] Budoucí 📅 2040-01-01
            - [ ] Dnes 📅 2026-11-06
            - [ ] Včera 📅 2026-11-05
            - [ ] Bez data
            - [ ] Nemožné 📅 2026-02-31
            - [ ] Konflikt 📅 2026-11-05 📅 2026-11-06
            - [x] Hotovo 📅 2020-01-01
            """, to: "Zeta.md")
        try vault.write("- [ ] Shoda 📅 2026-11-05\n", to: "Alfa.md")
        try vault.write("- [ ] Shoda 📅 2026-11-05\n", to: "Journal/2026/11/2026-11-04.md")
        let index = makeIndex()
        try await index.synchronize()
        let today = Day(year: 2026, month: 11, day: 6)

        let open = try await index.tasks(.open, on: today)
        #expect(open.map(\.relativePath) == [
            "Journal/2026/11/2026-11-04.md", "Alfa.md", "Zeta.md", "Zeta.md", "Zeta.md", "Zeta.md", "Zeta.md", "Zeta.md",
        ])
        #expect(open.map(\.ordinal) == [0, 0, 2, 1, 0, 3, 4, 5])
        #expect(Set(open.map(\.id)).count == 8)
        #expect(texts(try await index.tasks(.overdue, on: today)) == [
            "Shoda 📅 2026-11-05", "Shoda 📅 2026-11-05", "Včera 📅 2026-11-05",
        ])
        #expect(texts(try await index.tasks(.today, on: today)) == ["Dnes 📅 2026-11-06"])
        #expect(texts(try await index.tasks(.upcoming, on: today)) == ["Budoucí 📅 2040-01-01"])
        let undated = try await index.tasks(.undated, on: today)
        #expect(undated.map(\.dueDate.state) == [.missing, .invalid, .invalid])
        #expect(texts(try await index.tasks(.completed, on: today)) == ["Hotovo 📅 2020-01-01"])
    }

    @Test("external date edits, removal, reopening and rebuilding retain exactly the saved interpretation")
    func dueDateCacheLifecycle() async throws {
        let today = Day(year: 2026, month: 11, day: 6)
        try vault.write("- [ ] Poslat\n", to: "Plán.md")
        let index = makeIndex()
        try await index.synchronize()
        #expect(try await index.tasks(.undated, on: today).first?.dueDate.state == .missing)

        try vault.write("- [ ] Poslat 📅 2026-11-06\n", to: "Plán.md")
        try await index.update(relativePaths: ["Plán.md"])
        let dated = try await index.tasks(.today, on: today)
        #expect(dated.first?.dueDate.state == .valid(today))
        let reopened = makeIndex()
        try await reopened.synchronize()
        #expect(try await reopened.tasks(.today, on: today) == dated)
        try await reopened.rebuild()
        #expect(try await reopened.tasks(.today, on: today) == dated)

        let invalid = "- [ ] Poslat 📅 2026-11-06 📅 2026-11-07\n"
        try vault.write(invalid, to: "Plán.md")
        try await reopened.update(relativePaths: ["Plán.md"])
        #expect(try await reopened.tasks(.today, on: today).isEmpty)
        #expect(try await reopened.tasks(.undated, on: today).first?.dueDate.state == .invalid)
        try await reopened.rebuild()
        #expect(try await reopened.tasks(.undated, on: today).first?.dueDate.state == .invalid)
        #expect(try vault.read("Plán.md") == invalid)

        try vault.write("- [ ] Poslat\n", to: "Plán.md")
        try await reopened.update(relativePaths: ["Plán.md"])
        #expect(try await reopened.tasks(.undated, on: today).first?.dueDate.state == .missing)
        try FileManager.default.removeItem(at: vault.vault.rootURL.appendingPathComponent("Plán.md"))
        try await reopened.update(relativePaths: ["Plán.md"])
        #expect(try await reopened.tasks(.open, on: today).isEmpty)
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

    @Test("each Task carries its complete heading path of ATX and setext headings; headings in code are not structure and preamble Tasks have none")
    func headingPath() async throws {
        try vault.write("""
            - [ ] Úvodní

            # Projekt

            - [ ] Pod projektem

            ## Schůzka ##

            ```
            # není nadpis
            ```

            #### Akce

            - [ ] Hluboko

            Další část
            ----------

            - [ ] Pod setextem

            # Jiný

            - [ ] Jinde
            """, to: "Projekt.md")
        let index = makeIndex()
        try await index.synchronize()

        let paths = try await index.tasks(.open).map { [$0.text] + $0.headingPath }
        #expect(paths == [
            ["Úvodní"],
            ["Pod projektem", "Projekt"],
            ["Hluboko", "Projekt", "Schůzka", "Akce"],
            ["Pod setextem", "Projekt", "Další část"],
            ["Jinde", "Jiný"],
        ])
    }

    @Test("nested Tasks carry their enclosing Tasks; plain list items, other lists and a heading do not enclose")
    func enclosingTasks() async throws {
        try vault.write("""
            # Den

            - [x] Rodič hotový
              - [ ] Dítě otevřené
                - Poznámka bez políčka
                  - [ ] Vnouče
              - [ ] Druhé dítě
            - [ ] Soused
            1. [ ] Číslovaný rodič
               1) [ ] Číslované dítě

            Odstavec ukončí seznam.

              - [ ] Odsazený, ale nový seznam

            ## Další

            - [ ] Po nadpisu
            """, to: "Journal/2026/11/2026-11-05.md")
        let index = makeIndex()
        try await index.synchronize()

        let open = try await index.tasks(.open)
        #expect(open.map { [$0.text] + $0.enclosingTasks } == [
            ["Dítě otevřené", "Rodič hotový"],
            ["Vnouče", "Rodič hotový", "Dítě otevřené"],
            ["Druhé dítě", "Rodič hotový"],
            ["Soused"],
            ["Číslovaný rodič"],
            ["Číslované dítě", "Číslovaný rodič"],
            ["Odsazený, ale nový seznam"],
            ["Po nadpisu"],
        ])
        let parent = try #require(try await index.tasks(.completed).first)
        #expect(parent.text == "Rodič hotový" && parent.enclosingTasks.isEmpty)
    }

    private func savedTasks(_ text: String, at path: String = "Úkoly.md") async throws -> [TaskOccurrence] {
        try vault.write(text, to: path)
        let index = makeIndex()
        try await index.synchronize()
        return try await index.tasks(.open) + index.tasks(.completed)
    }

    @Test("a nested Task retains its enclosing Task across fenced code in the parent's list item")
    func enclosingTasksAcrossCode() async throws {
        let saved = """
            - [x] Parent
              ```
              - [ ] Example, not a Task
              ```
              - [ ] Child
            - [ ] Sibling
            """
        let tasks = try await savedTasks(saved)
        #expect(tasks.map(\.text) == ["Child", "Sibling", "Parent"])
        #expect(tasks.map(\.enclosingTasks) == [["Parent"], [], []])
    }

    @Test("quoted nested Tasks retain enclosing context without leaking it to other lists")
    func enclosingQuotedTasks() async throws {
        let saved = """
            > - [x] Parent
            >   - [ ] Child
            >     - [ ] Grandchild
            >
            > - [ ] Other parent
            >   - [ ] Child

            - [ ] Outside
            """
        let tasks = try await savedTasks(saved)
        #expect(tasks.map(\.text) == ["Child", "Grandchild", "Other parent", "Child", "Outside", "Parent"])
        #expect(tasks.map(\.enclosingTasks) == [["Parent"], ["Parent", "Child"], [], ["Other parent"], [], []])
        for task in tasks {
            #expect(task.locate(in: "Introduction\n\n" + saved) == .found(NSRange(
                location: task.boxLocation + ("Introduction\n\n" as NSString).length, length: 3
            )))
        }
    }

    @Test("an unchanged note locates the Task at its saved box; unsaved text before it moves it with the text")
    func locatingAfterInsertedAndRemovedText() async throws {
        let saved = "# Úkoly\n\nÚvod, který zmizí.\n\n- [ ] První\n- [ ] Druhý\n"
        let second = try #require(try await savedTasks(saved).first { $0.text == "Druhý" })

        #expect(second.locate(in: saved) == .found(NSRange(location: second.boxLocation, length: 3)))
        #expect(second.locate(in: saved + "Dopsáno\n") == .found(NSRange(location: second.boxLocation, length: 3)))

        let inserted = "# Úkoly\n\n👩‍👩‍👧 Nový odstavec se smajlíky 🎉 a Cafe\u{301}.\n\nÚvod, který zmizí.\n\n- [ ] Nový\n- [ ] První\n- [ ] Druhý\n"
        let found = try #require(boxRange(second.locate(in: inserted)))
        #expect(found.location > second.boxLocation)
        #expect(lineText(at: found, in: inserted) == "- [ ] Druhý")

        let removed = "# Úkoly\n\n- [ ] První\n- [ ] Druhý\n"
        let moved = try #require(boxRange(second.locate(in: removed)))
        #expect(moved.location < second.boxLocation)
        #expect(lineText(at: moved, in: removed) == "- [ ] Druhý")
    }

    @Test("Unicode in and before the Task: emoji and decomposed characters do not shift the located box")
    func locatingWithUnicode() async throws {
        let decomposed = "Zavolat Rene\u{301}e 👍🏽"
        let saved = "# Úkoly\n\n- [ ] \(decomposed)\n"
        let task = try #require(try await savedTasks(saved).first)
        #expect(task.text == decomposed)

        let current = "# Úkoly\n\nC\u{30C}as 🧑‍💻 a e\u{301}\n- [ ] \(decomposed)\n"
        let range = try #require(boxRange(task.locate(in: current)))
        #expect(lineText(at: range, in: current) == "- [ ] \(decomposed)")
    }

    @Test("identical Tasks are told apart by their heading path, enclosing Tasks and order, never by the first matching text")
    func locatingDuplicates() async throws {
        let saved = """
            # A

            - [ ] Zavolat
            - [ ] Zavolat
            - [ ] Rodič
              - [ ] Zavolat

            # B

            - [ ] Zavolat

            """
        let tasks = try await savedTasks(saved)
        let calls = tasks.filter { $0.text == "Zavolat" }
        #expect(calls.count == 4)
        let current = "Nový úvod\n\n" + saved.replacingOccurrences(of: "- [ ] Rodič\n", with: "- [ ] Jiný\n- [ ] Rodič\n")
            + "Dopsáno\n"
        let shift = ("Nový úvod\n\n" as NSString).length
        for (call, extra) in zip(calls, [0, 0, 11, 11]) {
            #expect(call.locate(in: current) == .found(NSRange(location: call.boxLocation + shift + extra, length: 3)))
        }
    }

    @Test("a Task that is gone, changed or under another heading is missing; a changed number of identical Tasks is ambiguous")
    func locatingChangedTasks() async throws {
        let saved = "# A\n\n- [ ] Zavolat\n- [ ] Zavolat\n- [ ] Jediný\n"
        let tasks = try await savedTasks(saved)
        let first = try #require(tasks.first)
        let only = try #require(tasks.last)

        #expect(only.locate(in: "# A\n\n- [ ] Zavolat\n- [ ] Zavolat\n") == .missing)
        #expect(only.locate(in: "# A\n\n- [ ] Zavolat\n- [ ] Zavolat\n- [ ] Jediný upravený\n") == .missing)
        #expect(only.locate(in: "# A\n\n- [ ] Zavolat\n- [ ] Zavolat\n## Nový\n- [ ] Jediný\n") == .missing)
        #expect(only.locate(in: "# A\n\n- [ ] Zavolat\n  - [ ] Jediný\n") == .missing)
        #expect(only.locate(in: "") == .missing)
        #expect(first.locate(in: "# A\n\n- [ ] Zavolat\n- [ ] Jediný\n") == .ambiguous)
        #expect(first.locate(in: saved + "- [ ] Zavolat\n") == .ambiguous)
        // A completed or reopened box is still the same Task.
        #expect(boxRange(only.locate(in: saved.replacingOccurrences(of: "[ ] Jediný", with: "[x] Jediný"))) != nil)
    }

    @Test("unchanged duplicate counts do not prove identity after reordering or replacing Tasks")
    func locatingReorderedDuplicates() async throws {
        let saved = "# Calls\n\n- [ ] Call\n  First client\n- [x] Call\n  Second client\n"
        let tasks = try await savedTasks(saved)
        let open = try #require(tasks.first { !$0.isCompleted })
        let completed = try #require(tasks.first { $0.isCompleted })
        let reordered = "# Calls\n\n- [x] Call\n  Second client\n- [ ] Call\n  First client\n"
        let replaced = "# Calls\n\n- [x] Call\n  Second client\n- [ ] Call\n  New client\n"

        for current in [reordered, replaced] {
            #expect(open.locate(in: current) == .ambiguous)
            #expect(completed.locate(in: current) == .ambiguous)
        }
        #expect(open.locate(in: saved) == .found(NSRange(location: open.boxLocation, length: 3)))
        #expect(completed.locate(in: saved) == .found(NSRange(location: completed.boxLocation, length: 3)))
        let reopened = makeIndex()
        try await reopened.synchronize()
        let cached = try #require(try await reopened.tasks(.open).first)
        #expect(cached == open)
        #expect(cached.locate(in: replaced) == .ambiguous)
        try await reopened.rebuild()
        #expect(try await reopened.tasks(.open).first == open)
    }

    private func boxRange(_ location: TaskOccurrence.Location) -> NSRange? {
        guard case .found(let range) = location else { return nil }
        return range
    }

    private func lineText(at range: NSRange, in text: String) -> String {
        let string = text as NSString
        return string.substring(with: string.lineRange(for: range)).trimmingCharacters(in: .newlines)
    }
}
