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
    /// Vault-relative paths the run cannot read (injected read failures).
    fileprivate let unreadable = Box<Set<String>>([])

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
        let unreadable = self.unreadable
        return BrainRun(
            vault: temp.vault,
            executableURL: URL(filePath: "/usr/local/bin/copilot"),
            store: store,
            runner: FakeRunner(body: body),
            now: { Date(timeIntervalSinceReferenceDate: 800_000_000) },
            capture: { vault, scope throws(VaultSnapshotError) in
                if let path = unreadable.current.sorted().first(where: {
                    scope.isEmpty || $0 == scope || $0.hasPrefix(scope + "/")
                }) {
                    throw VaultSnapshotError(relativePath: path, detail: "Permission denied")
                }
                return try VaultFileSnapshot.capture(of: vault, under: scope)
            }
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
        #expect(BrainRunChanges(since: record.snapshot, current: try VaultFileSnapshot.capture(of: temp.vault)).isEmpty)
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
            try holder.current?.acceptUserWrite(under: ["Projects/attachments/a.png", "Projects/Plan.md"])
            #expect(try holder.current?.changesOutsideBrain() == [])
            return 0
        }
        holder.current = run
        try FileManager.default.createDirectory(
            at: root.appending(path: "Projects/attachments"), withIntermediateDirectories: true
        )

        #expect(await run.run(log: { _ in }) == .succeeded(processed: 2))
        let record = try #require(try store.lastSuccessfulRun(for: temp.vault))
        #expect(BrainRunChanges(since: record.snapshot, current: try VaultFileSnapshot.capture(of: temp.vault)).changed
            == ["Projects/Plan.md"])
    }

    @Test("the Agent overwriting a note the user saved during the run is still reported")
    func agentOverwritesUserSave() async throws {
        let root = temp.vault.rootURL
        let holder = Box<BrainRun?>(nil)
        let run = brainRun { _, _ in
            let url = root.appending(path: "Projects/Plan.md")
            try "# Plan\n\nMine\n".write(to: url, atomically: true, encoding: .utf8)
            try holder.current?.acceptUserWrite(under: ["Projects/Plan.md"])
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

    @Test("a cancelled run leaves the Agent's emptied Brain Notes alone")
    func cancelledRunKeepsEmptyBrainNotes() async throws {
        write("# Old\n", "_brain/people/Old.md")
        let root = temp.vault.rootURL
        let run = brainRun { _, _ in
            try "".write(to: root.appending(path: "_brain/people/Old.md"), atomically: true, encoding: .utf8)
            try await Task.sleep(for: .seconds(30))
            return 0
        }
        let task = Task { await run.run(log: { _ in }) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        #expect(await task.value == .cancelled)
        #expect(temp.fileExists("_brain/people/Old.md"))
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

    private func unreadableFailurePath(_ outcome: BrainRunOutcome) -> String? {
        guard case .failed(.vaultUnreadable(let error)) = outcome else { return nil }
        return error.relativePath
    }

    @Test("an unreadable note stops the run before Copilot CLI starts and keeps the last successful run")
    func unreadableNoteBeforeLaunch() async throws {
        #expect(await brainRun { _, _ in 0 }.run(log: { _ in }) == .succeeded(processed: 2))
        let before = try #require(try store.lastSuccessfulRun(for: temp.vault))
        write("# Plan\n\nMore\n", "Projects/Plan.md")
        unreadable.current = ["Projects/Plan.md"]

        let launched = Box(false)
        let outcome = await brainRun { _, _ in
            launched.current = true
            return 0
        }.run(log: { _ in })

        #expect(unreadableFailurePath(outcome) == "Projects/Plan.md")
        #expect(!launched.current)
        #expect(try store.lastSuccessfulRun(for: temp.vault) == before)

        unreadable.current = []
        let prompt = Box("")
        #expect(await brainRun { command, _ in
            prompt.current = command.arguments[1]
            return 0
        }.run(log: { _ in }) == .succeeded(processed: 1))
        #expect(prompt.current.contains("`Projects/Plan.md`"))
    }

    @Test("a save during the start snapshot that cannot be read back stops the run before launch")
    func unreadableSaveBeforeLaunch() async throws {
        let holder = Box<BrainRun?>(nil)
        let unreadable = self.unreadable
        let run = BrainRun(
            vault: temp.vault,
            executableURL: URL(filePath: "/usr/local/bin/copilot"),
            store: store,
            runner: FakeRunner { _, _ in
                Issue.record("must not run")
                return 0
            },
            now: Date.init,
            capture: { vault, scope throws(VaultSnapshotError) in
                if unreadable.current.contains(scope) {
                    throw VaultSnapshotError(relativePath: scope, detail: "Permission denied")
                }
                let snapshot = try VaultFileSnapshot.capture(of: vault, under: scope)
                if scope.isEmpty {
                    // The user saves while the start snapshot is taken; the file then turns unreadable.
                    try? holder.current?.acceptUserWrite(under: ["Projects/Plan.md"])
                    unreadable.current = ["Projects/Plan.md"]
                }
                return snapshot
            }
        )
        holder.current = run

        let outcome = await run.run(log: { _ in })

        #expect(unreadableFailurePath(outcome) == "Projects/Plan.md")
        #expect(try store.lastSuccessfulRun(for: temp.vault) == nil)
    }

    @Test("a save that cannot be read back during the run fails the run and keeps the expected fingerprints")
    func unreadableUserSaveDuringRun() async throws {
        let root = temp.vault.rootURL
        let holder = Box<BrainRun?>(nil)
        let thrown = Box<VaultSnapshotError?>(nil)
        let unreadable = self.unreadable
        let run = brainRun { _, _ in
            try "# Plan\n\nMine\n".write(to: root.appending(path: "Projects/Plan.md"), atomically: true, encoding: .utf8)
            unreadable.current = ["Projects/Plan.md"]
            do throws(VaultSnapshotError) {
                try holder.current?.acceptUserWrite(under: ["Projects/Plan.md"])
            } catch {
                thrown.current = error
            }
            unreadable.current = []
            // The failed overlay did not replace the start fingerprint, so the save looks foreign.
            #expect(try holder.current?.changesOutsideBrain() == ["Projects/Plan.md"])
            return 0
        }
        holder.current = run

        let outcome = await run.run(log: { _ in })

        #expect(thrown.current?.relativePath == "Projects/Plan.md")
        #expect(unreadableFailurePath(outcome) == "Projects/Plan.md")
        #expect(try store.lastSuccessfulRun(for: temp.vault) == nil)
    }

    @Test("an unreadable file during the run fails the boundary check and the run, even if readable again")
    func unreadableFileDuringRun() async throws {
        let holder = Box<BrainRun?>(nil)
        let thrown = Box<VaultSnapshotError?>(nil)
        let unreadable = self.unreadable
        let run = brainRun { _, _ in
            unreadable.current = ["Journal/2026/03/2026-03-14.md"]
            do throws(VaultSnapshotError) {
                _ = try holder.current?.changesOutsideBrain()
            } catch {
                thrown.current = error
            }
            unreadable.current = []
            return 0
        }
        holder.current = run

        let outcome = await run.run(log: { _ in })

        #expect(thrown.current?.relativePath == "Journal/2026/03/2026-03-14.md")
        #expect(unreadableFailurePath(outcome) == "Journal/2026/03/2026-03-14.md")
        #expect(try store.lastSuccessfulRun(for: temp.vault) == nil)
    }

    @Test("a file unreadable at the final check fails the run instead of succeeding")
    func unreadableFileAtFinalCheck() async throws {
        let unreadable = self.unreadable
        let outcome = await brainRun { _, _ in
            unreadable.current = ["Projects/Plan.md"]
            return 0
        }.run(log: { _ in })

        #expect(unreadableFailurePath(outcome) == "Projects/Plan.md")
        #expect(try store.lastSuccessfulRun(for: temp.vault) == nil)
    }

    @Test("a note really deleted since the last run is still processed as deleted")
    func deletedNoteProcessed() async throws {
        _ = await brainRun { _, _ in 0 }.run(log: { _ in })
        try FileManager.default.removeItem(at: temp.vault.rootURL.appending(path: "Projects/Plan.md"))

        let prompt = Box("")
        let outcome = await brainRun { command, _ in
            prompt.current = command.arguments[1]
            return 0
        }.run(log: { _ in })

        #expect(outcome == .succeeded(processed: 1))
        #expect(prompt.current.contains("`Projects/Plan.md`"))
    }
}
