import Foundation
import Testing
@testable import Notess
@testable import NotessCore

private final class HoldingRunner: BrainRunProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var launched = 0
    var launchCount: Int { lock.withLock { launched } }

    func run(_ command: BrainRunCommand, output: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        lock.withLock { launched += 1 }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
        }
        throw CancellationError()
    }
}

@MainActor
private func eventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(20)
    while !condition() {
        try #require(ContinuousClock.now < deadline, "timed out")
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// Lets the main queue apply events the connection has queued.
@MainActor
private func drainMainQueue() async {
    for _ in 0..<3 {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

private final class Fixture {
    let rootURL: URL
    let otherURL: URL
    let storeURL: URL
    private let defaultsSuiteName = "NotessBrainConversationTests-\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "NotessBrainConversationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        rootURL = base.appending(path: "vault", directoryHint: .isDirectory)
        otherURL = base.appending(path: "other", directoryHint: .isDirectory)
        storeURL = base.appending(path: "state", directoryHint: .isDirectory)
        for url in [rootURL, otherURL] {
            try FileManager.default.createDirectory(at: url.appending(path: "_brain"), withIntermediateDirectories: true)
            try "# Plan\n".write(to: url.appending(path: "Plan.md"), atomically: true, encoding: .utf8)
            try "- Alice keeps the codeword [[Plan]]\n"
                .write(to: url.appending(path: "_brain/Alice.md"), atomically: true, encoding: .utf8)
        }
        defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: rootURL.deletingLastPathComponent())
    }

    var store: BrainRunStateStore { BrainRunStateStore(directoryURL: storeURL) }
    var vault: Vault { Vault(rootURL: rootURL) }

    @MainActor
    func makeModel(
        connections: Connections,
        runner: any BrainRunProcessRunner = HoldingRunner(),
        cliPath: String = "/bin/sh"
    ) -> AppModel {
        VaultLocationStore(defaults: defaults).remember(Vault(rootURL: rootURL))
        let settings = AppSettings(defaults: defaults)
        // Any executable satisfies the locator; the fake connection never starts it.
        settings.copilotCLIPath = cliPath
        return AppModel(
            vaultLocationStore: VaultLocationStore(defaults: defaults),
            tabRestorationStore: TabRestorationStore(defaults: defaults),
            settings: settings,
            brainRunStateStore: store,
            brainRunProcessRunner: runner,
            tagGroupStore: TagGroupStore(directoryURL: storeURL.appending(path: "tags", directoryHint: .isDirectory)),
            brainConversationConnection: connections.factory,
            now: { Date(timeIntervalSince1970: 1_760_765_000) }
        )
    }
}

@MainActor
@Suite("Brain Conversation in AppModel")
struct AppModelBrainConversationTests {
    @Test("a question streams its answer and activity, then completes when session/prompt answers")
    func askAndStream() async throws {
        let fixture = try Fixture()
        let connections = Connections()
        let model = fixture.makeModel(connections: connections)

        #expect(model.askBrainConversation("  Who keeps the codeword?  "))
        try await eventually { connections.made.first?.isPrompting == true }
        let connection = connections.last
        #expect(connection.vault == fixture.vault)
        #expect(connection.startCount == 1)
        #expect(connection.prompts == [[BrainConversationInstructions.text, "Who keeps the codeword?"]])
        #expect(model.isAgentOperationActive)
        #expect(model.agentOperations.current?.kind == .conversationTurn)

        connection.send(.event(.toolCall(id: "1", title: "Read _brain/Alice.md", kind: "read", status: .inProgress)))
        connection.send(.event(.answerChunk("Alice ")))
        try await eventually { model.brainConversation.conversation.turns.first?.answer == "Alice " }
        #expect(model.brainConversation.isTurnActive)
        #expect(model.brainConversation.conversation.turns[0].state == .running)

        connection.send(.event(.answerChunk("does.")))
        connection.send(.event(.permissionAllowed(title: "Run grep", option: "Allow once")))
        connection.send(.finish(.endTurn))
        try await eventually { !model.isAgentOperationActive }

        let turn = model.brainConversation.conversation.turns[0]
        #expect(turn.question == "Who keeps the codeword?")
        #expect(turn.answer == "Alice does.")
        #expect(turn.state == .completed)
        #expect(turn.activity.map(\.title).contains("Read _brain/Alice.md"))
        #expect(turn.activity.map(\.title).contains("Run grep"))
        #expect(!model.brainConversation.isTurnActive)
        #expect(await connection.isOpen())
        #expect(connection.closeCount == 0)
    }

    @Test("a final chunk alone does not complete the turn")
    func finalChunkIsNotCompletion() async throws {
        let fixture = try Fixture()
        let connections = Connections()
        let model = fixture.makeModel(connections: connections)

        model.askBrainConversation("Q")
        try await eventually { connections.made.first?.isPrompting == true }
        connections.last.send(.event(.answerChunk("Everything is done.")))
        try await eventually { model.brainConversation.conversation.turns[0].answer == "Everything is done." }
        try await Task.sleep(for: .milliseconds(30))

        #expect(model.brainConversation.conversation.turns[0].state == .running)
        #expect(model.isAgentOperationActive)

        connections.last.send(.finish(.endTurn))
        try await eventually { !model.isAgentOperationActive }
    }

    @Test("a follow-up continues the same Agent session; asking is unavailable while a turn runs")
    func followUp() async throws {
        let fixture = try Fixture()
        let connections = Connections()
        let model = fixture.makeModel(connections: connections)

        model.askBrainConversation("First?")
        try await eventually { connections.made.first?.isPrompting == true }
        #expect(!model.askBrainConversation("Too early?"))
        connections.last.send(.finish(.endTurn))
        try await eventually { !model.brainConversation.isTurnActive && !model.isAgentOperationActive }

        #expect(model.askBrainConversation("And then?"))
        try await eventually { connections.last.prompts.count == 2 && connections.last.isPrompting }
        connections.last.send(.event(.answerChunk("Later.")))
        connections.last.send(.finish(.endTurn))
        try await eventually { !model.isAgentOperationActive }

        #expect(connections.made.count == 1)
        #expect(connections.last.startCount == 1)
        #expect(connections.last.prompts[1] == ["And then?"])
        #expect(model.brainConversation.conversation.turns.map(\.question) == ["First?", "And then?"])
        #expect(model.brainConversation.conversation.turns.map(\.state) == [.completed, .completed])
    }

    @Test("Stop cancels the turn, keeps the partial answer marked incomplete and keeps the session")
    func stop() async throws {
        let fixture = try Fixture()
        let connections = Connections()
        let model = fixture.makeModel(connections: connections)

        model.askBrainConversation("Long?")
        try await eventually { connections.made.first?.isPrompting == true }
        connections.last.send(.event(.answerChunk("Part")))
        try await eventually { model.brainConversation.conversation.turns[0].answer == "Part" }

        model.stopBrainConversationTurn()
        #expect(model.brainConversation.conversation.turns[0].state == .stopping)
        try await eventually { !model.isAgentOperationActive }

        #expect(connections.last.cancelCount == 1)
        #expect(model.brainConversation.conversation.turns[0].answer == "Part")
        #expect(model.brainConversation.conversation.turns[0].state == .incomplete(reason: nil))
        #expect(await connections.last.isOpen())

        model.askBrainConversation("Shorter?")
        try await eventually { connections.last.prompts.count == 2 }
        #expect(connections.made.count == 1)
        connections.last.send(.finish(.endTurn))
        try await eventually { !model.isAgentOperationActive }
    }

    @Test("when the Agent ignores the cancel, its process group is terminated and the next question starts a new session")
    func stopTerminates() async throws {
        let fixture = try Fixture()
        let connections = Connections()
        connections.honoursCancel = false
        let model = fixture.makeModel(connections: connections)

        model.askBrainConversation("Long?")
        try await eventually { connections.made.first?.isPrompting == true }
        model.stopBrainConversationTurn()
        try await eventually { !model.isAgentOperationActive }

        #expect(model.brainConversation.conversation.turns[0].state == .incomplete(reason: nil))
        #expect(connections.made[0].closeCount >= 1)
        #expect(!model.ownsAgentProcesses)

        connections.honoursCancel = true
        model.askBrainConversation("Again?")
        try await eventually { connections.made.count == 2 && connections.last.isPrompting }
        #expect(connections.last.prompts[0] == [BrainConversationInstructions.text, "Again?"])
        connections.last.send(.finish(.endTurn))
        try await eventually { !model.isAgentOperationActive }
    }

    @Test("a missing Copilot CLI is an explicit error and starts nothing")
    func missingCLI() async throws {
        let fixture = try Fixture()
        let connections = Connections()
        let model = fixture.makeModel(connections: connections, cliPath: "/nonexistent/copilot")

        model.askBrainConversation("Q")
        try await eventually { !model.isAgentOperationActive }

        guard case .failed(let message) = model.brainConversation.conversation.turns[0].state else {
            Issue.record("expected a failure")
            return
        }
        #expect(message.contains("/nonexistent/copilot"))
        #expect(connections.made.isEmpty)
    }

    @Test(
        "sandbox, authentication, protocol and exit failures are errors, never answers",
        arguments: [
            (BrainConversationError.sandbox(.unavailable("sandbox-exec chybí")), "Agent nebyl spuštěn"),
            (.sandbox(.ineffective), "Agent nebyl spuštěn"),
            (.sandbox(.outsideHardLinks(["Plan.md"])), "Plan.md"),
            (.authentication("Not logged in"), "přihlaste"),
            (.protocolViolation("bad"), "bad"),
        ]
    )
    func startFailures(error: BrainConversationError, expected: String) async throws {
        let fixture = try Fixture()
        let connections = Connections()
        connections.startError = error
        let model = fixture.makeModel(connections: connections)

        model.askBrainConversation("Q")
        try await eventually { !model.isAgentOperationActive }

        guard case .failed(let message) = model.brainConversation.conversation.turns[0].state else {
            Issue.record("expected a failure")
            return
        }
        #expect(message.contains(expected))
        #expect(connections.last.prompts.isEmpty)
        #expect(connections.last.closeCount == 1)
        #expect(!model.ownsAgentProcesses)
    }

    @Test("a CLI exit during a turn fails it, keeps what streamed, and the next question starts a new session")
    func exitDuringTurn() async throws {
        let fixture = try Fixture()
        let connections = Connections()
        let model = fixture.makeModel(connections: connections)

        model.askBrainConversation("Q")
        try await eventually { connections.made.first?.isPrompting == true }
        connections.last.send(.event(.answerChunk("half")))
        connections.last.send(.fail(.exited(status: 1, detail: "fatal")))
        try await eventually { !model.isAgentOperationActive }

        let turn = model.brainConversation.conversation.turns[0]
        #expect(turn.answer == "half")
        #expect(turn.state == .failed("Copilot CLI se neočekávaně ukončil (kód 1). fatal"))
        #expect(!model.ownsAgentProcesses)

        model.askBrainConversation("Again")
        try await eventually { connections.made.count == 2 && connections.last.isPrompting }
        connections.last.send(.finish(.endTurn))
        try await eventually { !model.isAgentOperationActive }
    }

    @Test("a Vault switch while streaming stops the turn, rejects its late events and owns the Vault until cleanup")
    func vaultSwitchWhileStreaming() async throws {
        let fixture = try Fixture()
        let connections = Connections()
        connections.holdsClose = true
        let runner = HoldingRunner()
        let model = fixture.makeModel(connections: connections, runner: runner)

        model.askBrainConversation("Q")
        try await eventually { connections.made.first?.isPrompting == true }
        let old = connections.last
        old.send(.event(.answerChunk("old")))
        try await eventually { model.brainConversation.conversation.turns.first?.answer == "old" }

        model.chooseVault(at: fixture.otherURL)
        #expect(model.brainConversation.conversation.turns.isEmpty)
        #expect(!model.brainConversation.isTurnActive)
        try await eventually { old.closeCount == 1 }
        old.sendLate(.answerChunk(" late"))
        await drainMainQueue()

        #expect(old.cancelCount == 1)
        #expect(model.brainConversation.conversation.turns.isEmpty)
        #expect(model.isAgentOperationActive)
        model.startBrainRun()
        #expect(!model.askBrainConversation("New?"))
        try await Task.sleep(for: .milliseconds(30))
        #expect(runner.launchCount == 0)
        #expect(connections.made.count == 1)

        old.releaseClose()
        try await eventually { !model.isAgentOperationActive }
        #expect(model.brainConversation.conversation.turns.isEmpty)

        connections.holdsClose = false
        #expect(model.askBrainConversation("New?"))
        try await eventually { connections.made.count == 2 && connections.last.isPrompting }
        #expect(connections.last.vault == Vault(rootURL: fixture.otherURL))
        connections.last.send(.finish(.endTurn))
        try await eventually { !model.isAgentOperationActive }
    }

    @Test("leaving a Vault closes its idle Agent through the shared boundary")
    func vaultSwitchWhileIdle() async throws {
        let fixture = try Fixture()
        let connections = Connections()
        connections.holdsClose = true
        let runner = HoldingRunner()
        let model = fixture.makeModel(connections: connections, runner: runner)
        model.askBrainConversation("Q")
        try await eventually { connections.made.first?.isPrompting == true }
        connections.last.send(.finish(.endTurn))
        try await eventually { !model.isAgentOperationActive }
        let idle = connections.last
        #expect(idle.closeCount == 0)
        #expect(model.ownsAgentProcesses)

        model.chooseVault(at: fixture.otherURL)
        try await eventually { idle.closeCount == 1 }
        #expect(model.isAgentOperationActive)
        model.startBrainRun()
        try await Task.sleep(for: .milliseconds(30))
        #expect(runner.launchCount == 0)

        idle.releaseClose()
        try await eventually { !model.isAgentOperationActive }
        #expect(!model.ownsAgentProcesses)
        model.startBrainRun()
        try await eventually { runner.launchCount == 1 }
        model.cancelBrainRun()
        try await eventually { !model.isAgentOperationActive }
    }

    @Test("leaving a Vault right after a follow-up starts still closes the Agent kept between turns")
    func vaultSwitchBeforeFollowUpPicksUpAgent() async throws {
        let fixture = try Fixture()
        let connections = Connections()
        connections.holdsClose = true
        let runner = HoldingRunner()
        let model = fixture.makeModel(connections: connections, runner: runner)
        model.askBrainConversation("Q")
        try await eventually { connections.made.first?.isPrompting == true }
        connections.last.send(.finish(.endTurn))
        try await eventually { !model.isAgentOperationActive }
        let kept = connections.last

        // The turn's task has not run yet, so it has not picked up the kept Agent.
        #expect(model.askBrainConversation("Follow-up?"))
        model.chooseVault(at: fixture.otherURL)

        try await eventually { kept.closeCount >= 1 }
        #expect(model.isAgentOperationActive)
        kept.releaseClose()
        try await eventually { !model.isAgentOperationActive }
        #expect(!model.ownsAgentProcesses)
        #expect(connections.made.count == 1)
        #expect(kept.prompts.count == 1)
    }

    @Test("stale events of a finished turn are rejected")
    func lateEventsAfterFinish() async throws {
        let fixture = try Fixture()
        let connections = Connections()
        let model = fixture.makeModel(connections: connections)

        model.askBrainConversation("Q")
        try await eventually { connections.made.first?.isPrompting == true }
        connections.last.send(.event(.answerChunk("Done.")))
        connections.last.send(.finish(.endTurn))
        try await eventually { !model.isAgentOperationActive }
        connections.last.sendLate(.answerChunk(" Late."))
        await drainMainQueue()

        #expect(model.brainConversation.conversation.turns[0].answer == "Done.")
        #expect(model.brainConversation.conversation.turns[0].state == .completed)
    }

    @Test("a conversation turn and a Brain Run exclude each other; turns never touch the Brain Run baseline")
    func brainRunExclusion() async throws {
        let fixture = try Fixture()
        let connections = Connections()
        let runner = HoldingRunner()
        let model = fixture.makeModel(connections: connections, runner: runner)

        model.askBrainConversation("Q")
        try await eventually { connections.made.first?.isPrompting == true }
        model.startBrainRun()
        try await Task.sleep(for: .milliseconds(30))
        #expect(runner.launchCount == 0)
        #expect(model.brainRunPhase == .idle)
        connections.last.send(.finish(.endTurn))
        try await eventually { !model.isAgentOperationActive }

        #expect(model.lastSuccessfulBrainRun == nil)
        #expect(try fixture.store.lastSuccessfulRun(for: fixture.vault) == nil)

        model.startBrainRun()
        try await eventually { runner.launchCount == 1 }
        #expect(!model.askBrainConversation("During the run?"))
        #expect(model.brainConversation.refusal?.contains("Brain Run") == true)
        #expect(model.brainConversation.conversation.turns.count == 1)
        #expect(connections.last.prompts.count == 1)

        model.cancelBrainRun()
        try await eventually { !model.isAgentOperationActive }
        #expect(model.askBrainConversation("After the run?"))
        #expect(model.brainConversation.refusal == nil)
        try await eventually { connections.last.prompts.count == 2 }
        connections.last.send(.finish(.endTurn))
        try await eventually { !model.isAgentOperationActive }
        #expect(try fixture.store.lastSuccessfulRun(for: fixture.vault) == nil)
    }

    @Test("only saved files reach the Agent: unsaved edits are neither sent nor saved")
    func unsavedChangesStayLocal() async throws {
        let fixture = try Fixture()
        let connections = Connections()
        let model = fixture.makeModel(connections: connections)
        let document = try #require(model.openExistingNote(relativePath: "Plan.md"))
        document.text = "# Plan\nUNSAVED SECRET\n"

        model.askBrainConversation("What is the plan?")
        try await eventually { connections.made.first?.isPrompting == true }
        connections.last.send(.finish(.endTurn))
        try await eventually { !model.isAgentOperationActive }

        #expect(!connections.last.prompts.joined().joined().contains("UNSAVED SECRET"))
        #expect(try String(contentsOf: fixture.rootURL.appending(path: "Plan.md"), encoding: .utf8) == "# Plan\n")
        #expect(model.hasUnsavedChanges)
    }

    @Test("quitting stops a running turn and waits until its Agent is closed")
    func quitDuringTurn() async throws {
        let fixture = try Fixture()
        let connections = Connections()
        connections.holdsClose = true
        let model = fixture.makeModel(connections: connections)

        model.askBrainConversation("Q")
        try await eventually { connections.made.first?.isPrompting == true }
        let finished = Flag()
        let quitting = Task { @MainActor in
            await model.terminateAgentOperations()
            finished.value = true
        }
        try await eventually { connections.last.closeCount == 1 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!finished.value)
        #expect(connections.last.cancelCount == 1)

        connections.last.releaseClose()
        await quitting.value
        #expect(!model.ownsAgentProcesses)
        #expect(model.brainConversation.conversation.turns[0].state == .incomplete(reason: nil))
    }
}

@MainActor
private final class Flag {
    var value = false
}
