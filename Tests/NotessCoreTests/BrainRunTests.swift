import Foundation
import Testing
@testable import NotessCore

/// Stands in for Copilot CLI: runs `body` (playing the Agent) instead of a process.
private struct FakeRunner: BrainRunProcessRunner {
    var body: @Sendable (BrainRunCommand, @Sendable (String) -> Void) async throws -> Int32

    func run(_ command: BrainRunCommand, output: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        try await body(command, output)
    }
}

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    var current: Value {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

@Suite("Brain Run")
struct BrainRunTests {
    let temp: TemporaryVault
    let store: BrainRunStateStore
    let storeDirectory: URL

    init() throws {
        temp = try TemporaryVault()
        storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotessBrainRunState-\(UUID().uuidString)", isDirectory: true)
        store = BrainRunStateStore(directoryURL: storeDirectory)
        try temp.write("# 2026-03-14\n\n## Meeting\n\nMet Anna.\n", to: "Journal/2026/03/2026-03-14.md")
        try temp.write("# Plan\n", to: "Projects/Plan.md")
    }

    private func brainRun(
        _ body: @escaping @Sendable (BrainRunCommand, @Sendable (String) -> Void) async throws -> Int32
    ) -> BrainRun {
        BrainRun(
            vault: temp.vault,
            executableURL: URL(filePath: "/usr/local/bin/copilot"),
            store: store,
            runner: FakeRunner(body: body),
            now: { Date(timeIntervalSinceReferenceDate: 800_000_000) }
        )
    }

    private func write(_ text: String, _ relativePath: String) {
        try? temp.write(text, to: relativePath)
    }

    @Test("runs Copilot CLI in the Vault with the notes to process, and remembers the run on success")
    func successfulRun() async throws {
        let captured = Box<BrainRunCommand?>(nil)
        let root = temp.vault.rootURL
        let outcome = await brainRun { command, output in
            captured.current = command
            output("working\n")
            try "# Anna\n\n- Met. [[2026-03-14#Meeting]]\n".write(
                to: root.appending(path: "_brain/people/Anna.md"), atomically: true, encoding: .utf8
            )
            return 0
        }.run(log: { _ in })

        #expect(outcome == .succeeded(processed: 2))
        let command = try #require(captured.current)
        #expect(command.currentDirectoryURL == root)
        #expect(command.arguments[1].contains("`Journal/2026/03/2026-03-14.md`"))
        #expect(command.arguments[1].contains("`Projects/Plan.md`"))
        #expect(command.arguments[1].contains("Instructions for the Agent"))
        let record = try #require(try store.lastSuccessfulRun(for: temp.vault))
        #expect(record.completedAt == Date(timeIntervalSinceReferenceDate: 800_000_000))
        #expect(BrainRunChanges(since: record.snapshot, current: VaultFileSnapshot.capture(of: temp.vault)).isEmpty)
    }

    @Test("the next run processes only what changed since, and nothing when nothing changed")
    func nextRun() async throws {
        _ = await brainRun { _, _ in 0 }.run(log: { _ in })
        #expect(await brainRun { _, _ in Issue.record("must not run"); return 0 }.run(log: { _ in }) == .nothingToProcess)

        write("# Plan\n\n## Goals\n\nShip.\n", "Projects/Plan.md")
        let prompt = Box("")
        let outcome = await brainRun { command, _ in
            prompt.current = command.arguments[1]
            return 0
        }.run(log: { _ in })

        #expect(outcome == .succeeded(processed: 1))
        #expect(prompt.current.contains("`Projects/Plan.md`"))
        #expect(!prompt.current.contains("`Journal/2026/03/2026-03-14.md`"))
    }

    @Test("a failed run is not remembered, so its notes are processed again")
    func failedRun() async throws {
        let outcome = await brainRun { _, output in
            output("auth error\n")
            return 1
        }.run(log: { _ in })

        #expect(outcome == .failed(.exitStatus(1)))
        #expect(try store.lastSuccessfulRun(for: temp.vault) == nil)
    }

    @Test("a cancelled run is not remembered")
    func cancelledRun() async throws {
        let run = brainRun { _, _ in
            try await Task.sleep(for: .seconds(30))
            return 0
        }
        let task = Task { await run.run(log: { _ in }) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        #expect(await task.value == .cancelled)
        #expect(try store.lastSuccessfulRun(for: temp.vault) == nil)
    }

    @Test("a change outside _brain/ not made by the user fails the run")
    func changeOutsideBrain() async throws {
        let root = temp.vault.rootURL
        let outcome = await brainRun { _, _ in
            try "# Plan\n\nHacked\n".write(to: root.appending(path: "Projects/Plan.md"), atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: root.appending(path: "Journal/2026/03/2026-03-14.md"))
            try "x".write(to: root.appending(path: "new.md"), atomically: true, encoding: .utf8)
            return 0
        }.run(log: { _ in })

        #expect(outcome == .failed(.changedOutsideBrain([
            "Journal/2026/03/2026-03-14.md", "Projects/Plan.md", "new.md",
        ])))
        #expect(try store.lastSuccessfulRun(for: temp.vault) == nil)
    }

    @Test("the user's own saves during a run are not reported, and are processed by the next run")
    func userSavesDuringRun() async throws {
        let root = temp.vault.rootURL
        let holder = Box<BrainRun?>(nil)
        let run = brainRun { _, _ in
            try "# Plan\n\n## Goals\n".write(to: root.appending(path: "Projects/Plan.md"), atomically: true, encoding: .utf8)
            try "png".write(to: root.appending(path: "Projects/attachments/a.png"), atomically: false, encoding: .utf8)
            holder.current?.acceptUserWrite(under: ["Projects/Plan.md", "Projects/attachments"])
            #expect(holder.current?.changesOutsideBrain() == [])
            return 0
        }
        holder.current = run
        try FileManager.default.createDirectory(
            at: root.appending(path: "Projects/attachments"), withIntermediateDirectories: true
        )

        #expect(await run.run(log: { _ in }) == .succeeded(processed: 2))
        let record = try #require(try store.lastSuccessfulRun(for: temp.vault))
        #expect(BrainRunChanges(since: record.snapshot, current: VaultFileSnapshot.capture(of: temp.vault)).changed
            == ["Projects/Plan.md"])
    }

    @Test("the Agent overwriting a note the user saved during the run is still reported")
    func agentOverwritesUserSave() async throws {
        let root = temp.vault.rootURL
        let holder = Box<BrainRun?>(nil)
        let run = brainRun { _, _ in
            let url = root.appending(path: "Projects/Plan.md")
            try "# Plan\n\nMine\n".write(to: url, atomically: true, encoding: .utf8)
            holder.current?.acceptUserWrite(under: ["Projects/Plan.md"])
            try "# Plan\n\nAgent\n".write(to: url, atomically: true, encoding: .utf8)
            return 0
        }
        holder.current = run

        #expect(await run.run(log: { _ in }) == .failed(.changedOutsideBrain(["Projects/Plan.md"])))
    }

    @Test("empty Brain Notes are deleted after the run; other Brain Notes and AGENTS.md stay")
    func emptyBrainNotesDeleted() async throws {
        write("# Bob\n\n- Fact. [[Plan#Goals]]\n", "_brain/people/Bob.md")
        write("# Old\n", "_brain/people/Old.md")
        let root = temp.vault.rootURL
        _ = await brainRun { _, _ in
            try "  \n".write(to: root.appending(path: "_brain/people/Old.md"), atomically: true, encoding: .utf8)
            return 0
        }.run(log: { _ in })

        #expect(!temp.fileExists("_brain/people/Old.md"))
        #expect(temp.fileExists("_brain/people/Bob.md"))
        #expect(temp.fileExists("_brain/AGENTS.md"))
    }

    @Test("Entity type folders exist before the Agent starts, since it cannot create folders itself")
    func entityFoldersCreated() async throws {
        let root = temp.vault.rootURL
        let existed = Box(false)
        _ = await brainRun { _, _ in
            existed.current = ["people", "companies", "projects", "places"].allSatisfy {
                FileManager.default.fileExists(atPath: root.appending(path: "_brain/\($0)").path)
            }
            return 0
        }.run(log: { _ in })

        #expect(existed.current)
    }

    @Test("the run log contains the Agent's output")
    func logContainsOutput() async throws {
        let log = Box("")
        _ = await brainRun { _, output in
            output("Created _brain/people/Anna.md\n")
            return 0
        }.run(log: { log.current += $0 })

        #expect(log.current.contains("Created _brain/people/Anna.md"))
    }
}
