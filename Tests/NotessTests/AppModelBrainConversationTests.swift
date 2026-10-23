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
private func eventually(line: Int = #line, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(20)
    while !condition() {
        try #require(ContinuousClock.now < deadline, "timed out waiting at line \(line)")
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
    var conversationStoreURL: URL { storeURL.appending(path: "conversations", directoryHint: .isDirectory) }
    var conversationStore: BrainConversationStore { BrainConversationStore(directoryURL: conversationStoreURL) }
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
            brainConversationStore: conversationStore,
            now: { Date(timeIntervalSince1970: 1_760_765_000) }
        )
    }
}

@MainActor
@Suite("Brain Conversation in AppModel")
struct AppModelBrainConversationTests {
    @Test("a source can select a never-saved Daily Entry without creating it or sending its draft")
    func inMemoryDailyEntrySource() throws {
        let fixture = try Fixture()
        let model = fixture.makeModel(connections: Connections())
        let daily = try #require(model.document)
        #expect(!daily.existsOnDisk)
        daily.text += "\n## Local\n\nDraft only.\n"
        let relativePath = String(daily.fileURL.path.dropFirst(fixture.rootURL.path.count + 1))
        let source = BrainConversationEvidence.noteURL(target: relativePath, section: "Local")
        _ = model.openExistingNote(relativePath: "Plan.md")
        #expect(model.brainConversationSourceCategory(source) == "Původní poznámka · Daily Entry")

        model.openBrainConversationSource(source)

        #expect(model.document === daily)
        #expect(daily.text.contains("Draft only."))
        #expect(model.reveal?.range == NoteSection.find("Local", in: daily.text)?.headingRange)
        #expect(!FileManager.default.fileExists(atPath: daily.fileURL.path))
        #expect(model.errorMessage == nil)
    }

    @Test("evidence renders clickable Brain, original and external sources, ignoring code examples")
    func evidenceRendering() async throws {
        let fixture = try Fixture()
        let connections = Connections()
        let model = fixture.makeModel(connections: connections)
        try "## Rozhodnutí\n".write(to: fixture.rootURL.appending(path: "Žluťoučký ).md"), atomically: true, encoding: .utf8)
        let answer = """
        Brain Note: **supported** [[_brain/Alice]].
        Original note fallback: [[Žluťoučký )#Rozhodnutí]].
        External: [Reference](https://example.com/evidence).
        Not a source: `[[Absent]]` or `https://example.com/code`.
        """
        model.askBrainConversation("Evidence?")
        try await eventually { connections.made.first?.isPrompting == true }
        connections.last.send(.event(.answerChunk(answer)))
        connections.last.send(.finish(.endTurn))
        try await eventually { !model.isAgentOperationActive }
        let sources = BrainConversationEvidence.sources(in: model.brainConversation.conversation.turns[0].answer)
        #expect(sources.count == 3)
        #expect(sources.map { model.brainConversationSourceCategory($0.url) } == [
            "Brain Note", "Původní poznámka · Free Note", "Externí zdroj",
        ])
        let rendered = BrainConversationAnswer.attributedText(answer)
        let links = rendered.runs.compactMap(\.link)
        #expect(links == sources.map(\.url))
        model.openBrainConversationSource(sources[1].url)
        #expect(model.document?.displayName == "Žluťoučký )")
        #expect(model.reveal?.range == NSRange(location: 0, length: 13))
    }

    @Test("missing notes and Sections and invalid source targets give explicit feedback without writes")
    func invalidEvidence() throws {
        let fixture = try Fixture()
        let model = fixture.makeModel(connections: Connections())
        model.isBrainConversationPresented = true
        let before = try fixture.vault.scanNotePaths().sorted().map { path in
            (path, try Data(contentsOf: fixture.rootURL.appending(path: path)))
        }
        for url in [
            BrainConversationEvidence.noteURL(target: "Absent", section: nil),
            BrainConversationEvidence.noteURL(target: "Plan", section: "Absent"),
            BrainConversationEvidence.noteURL(target: "../Plan", section: nil),
            BrainConversationEvidence.noteURL(target: "", section: "Plan"),
            try #require(URL(string: "file:///tmp/Plan.md")),
            try #require(URL(string: "notess-source://note?target=Plan&target=Other")),
            try #require(URL(string: "javascript:alert(1)")),
        ] {
            model.errorMessage = nil
            model.openBrainConversationSource(url, openWeb: { _ in
                Issue.record("invalid evidence must not open external applications")
                return false
            })
            #expect(model.errorMessage != nil, "\(url)")
            #expect(model.isBrainConversationPresented)
        }
        #expect(fixture.vault.scanNotePaths().sorted() == before.map(\.0))
        for (path, data) in before {
            #expect(try Data(contentsOf: fixture.rootURL.appending(path: path)) == data)
        }
        let external = try #require(URL(string: "https://example.com/evidence"))
        var opened: URL?
        model.errorMessage = nil
        model.openBrainConversationSource(external, openWeb: { opened = $0; return true })
        #expect(opened == external)
        #expect(model.errorMessage == nil)
        model.openBrainConversationSource(external, openWeb: { _ in false })
        #expect(model.errorMessage?.contains("https://example.com/evidence") == true)
    }

    @Test("streamed tool details retain commands, URLs, files and outcomes across sparse updates without inventing missing data")
    func inspectableActivity() async throws {
        let fixture = try Fixture()
        let connections = Connections()
        let model = fixture.makeModel(connections: connections)
        model.askBrainConversation("Investigate")
        try await eventually { connections.made.first?.isPrompting == true }
        let input: JSONValue = .object(["command": .string("cat _brain/Alice.md"), "url": .string("https://example.com")])
        connections.last.send(.event(.toolCall(id: "read", title: "Read evidence", kind: "execute", status: .inProgress)))
        connections.last.send(.event(.toolDetails(id: "read", details: .init(
            input: input, locations: [.object(["path": .string("_brain/Alice.md"), "line": .number(2)])]
        ))))
        try await eventually {
            model.brainConversation.conversation.turns[0].activity.last?.details.input == input
        }
        connections.last.send(.event(.toolDetails(id: "read", details: .init(output: .string("Alice keeps the codeword.")))))
        connections.last.send(.event(.toolCallUpdate(id: "read", title: nil, status: .completed)))
        connections.last.send(.event(.toolCall(id: "sparse", title: "Search", kind: nil, status: .failed)))
        connections.last.send(.event(.permissionAllowed(title: "Unexpected permission", option: "Allow once")))
        connections.last.send(.finish(.endTurn))
        try await eventually { !model.isAgentOperationActive }
        let activity = model.brainConversation.conversation.turns[0].activity
        let read = try #require(activity.first { $0.id == "tool:read" })
        #expect(read.details.input == input)
        #expect(read.details.output == .string("Alice keeps the codeword."))
        #expect(read.details.locations == [.object(["path": .string("_brain/Alice.md"), "line": .number(2)])])
        #expect(read.kind == .tool(kind: "execute", status: .completed))
        #expect(activity.first { $0.id == "tool:sparse" }?.details == .init())
        #expect(activity.last?.kind == .permission(option: "Allow once"))
    }

    @Test("answer evidence opens a deleted dirty tab at its current Section without changing the conversation or saved inputs")
    func evidenceNavigation() async throws {
        let fixture = try Fixture()
        let connections = Connections()
        let model = fixture.makeModel(connections: connections)
        model.isBrainConversationPresented = true
        let document = try #require(model.openExistingNote(relativePath: "Plan.md"))
        document.text = "# Plan\n\n## Current\n\nUNSAVED-SECRET\n"
        try FileManager.default.removeItem(at: document.fileURL)
        document.reconcileWithDisk()
        _ = model.openExistingNote(relativePath: "_brain/Alice.md")

        model.askBrainConversation("What supports this?")
        try await eventually { connections.made.first?.isPrompting == true }
        connections.last.send(.event(.answerChunk("Original note fallback: [[Plan#Current]]. External: [reference](https://example.com/evidence).")))
        connections.last.send(.finish(.endTurn))
        try await eventually { !model.isAgentOperationActive }
        let turn = try #require(model.brainConversation.conversation.turns.last)
        let source = try #require(BrainConversationEvidence.sources(in: turn.answer).first)

        model.openBrainConversationSource(source.url)

        #expect(model.document === document)
        #expect(document.text.contains("UNSAVED-SECRET"))
        #expect(document.hasUnsavedChanges)
        #expect(model.reveal?.range == NoteSection.find("Current", in: document.text)?.headingRange)
        #expect(model.isBrainConversationPresented)
        #expect(model.brainConversation.conversation.turns.last == turn)
        #expect(!connections.last.prompts.joined().joined().contains("UNSAVED-SECRET"))
        #expect(!FileManager.default.fileExists(atPath: document.fileURL.path))
        #expect(model.errorMessage == nil)
    }

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

    @Test("when the Agent ignores the cancel, its process group is terminated and the next question resumes the saved session")
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
        #expect(connections.last.resumedSessions.count == 1)
        #expect(connections.last.prompts[0] == ["Again?"], "the resumed session already holds the instructions")
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

    @Test("a CLI exit during a turn fails it, keeps what streamed, and the next question resumes the saved session")
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

        let session = try #require(model.brainConversation.conversation.sessionID)
        model.askBrainConversation("Again")
        try await eventually { connections.made.count == 2 && connections.last.isPrompting }
        #expect(connections.last.resumedSessions == [session])
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
        try await eventually { old.closeCount >= 1 }
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
@Suite("Brain Conversation history in AppModel")
struct AppModelBrainConversationHistoryTests {
    private func finishedConversation(_ fixture: Fixture, connections: Connections) async throws -> AppModel {
        let model = fixture.makeModel(connections: connections)
        model.askBrainConversation("Who keeps the codeword?")
        try await eventually { connections.made.first?.isPrompting == true }
        connections.last.send(.event(.toolCall(id: "1", title: "Read _brain/Alice.md", kind: "read", status: .completed)))
        connections.last.send(.event(.answerChunk("Alice.")))
        connections.last.send(.finish(.endTurn))
        try await eventually { !model.isAgentOperationActive && model.brainConversation.conversation.turns[0].state == .completed }
        return model
    }

    @Test("new conversations have fresh context and all histories and the selection survive a restart")
    func multipleConversations() async throws {
        let fixture = try Fixture()
        let connections = Connections()
        let model = try await finishedConversation(fixture, connections: connections)
        let first = model.brainConversation.conversation

        #expect(model.createBrainConversation())
        let secondID = model.brainConversation.conversation.id
        #expect(secondID != first.id)
        #expect(model.brainConversation.conversation.turns.isEmpty)
        #expect(model.brainConversation.conversation.sessionID == nil)
        #expect(!model.brainConversation.conversation.sessionHasInstructions)
        #expect(model.brainConversation.conversations.count == 2)
        try await eventually { !model.isAgentOperationActive }
        #expect(model.askBrainConversation("Unrelated?"))
        try await eventually { connections.made.count == 2 && connections.last.isPrompting }
        #expect(connections.last.resumedSessions.isEmpty)
        #expect(connections.last.prompts == [[BrainConversationInstructions.text, "Unrelated?"]])
        connections.last.send(.event(.answerChunk("Separate answer.")))
        connections.last.send(.finish(.endTurn))
        try await eventually { !model.isAgentOperationActive }
        let secondSession = try #require(model.brainConversation.conversation.sessionID)
        #expect(secondSession != first.sessionID)

        #expect(model.selectBrainConversation(first.id))
        #expect(model.brainConversation.conversation == first)
        try await eventually { !model.isAgentOperationActive }

        let resumed = Connections()
        let reopened = fixture.makeModel(connections: resumed)
        #expect(reopened.brainConversation.conversation == first)
        #expect(reopened.brainConversation.conversations.count == 2)
        #expect(reopened.askBrainConversation("Follow up?"))
        try await eventually { resumed.made.first?.isPrompting == true }
        #expect(resumed.last.resumedSessions == [first.sessionID!])
        #expect(resumed.last.prompts == [["Follow up?"]])
        resumed.last.send(.event(.answerChunk("Still Alice.")))
        resumed.last.send(.finish(.endTurn))
        try await eventually { !reopened.isAgentOperationActive }

        #expect(reopened.selectBrainConversation(secondID))
        #expect(reopened.brainConversation.conversation.turns.map(\.question) == ["Unrelated?"])
        #expect(reopened.brainConversation.conversation.turns.map(\.answer) == ["Separate answer."])
        #expect(reopened.brainConversation.conversation.sessionID == secondSession)
        try await eventually { !reopened.isAgentOperationActive }
        #expect(reopened.askBrainConversation("Continue unrelated?"))
        try await eventually { resumed.made.count == 2 && resumed.last.isPrompting }
        #expect(resumed.last.resumedSessions == [secondSession])
        #expect(resumed.last.prompts == [["Continue unrelated?"]])
        resumed.last.send(.finish(.endTurn))
        try await eventually { !reopened.isAgentOperationActive }

        let again = fixture.makeModel(connections: Connections())
        #expect(again.brainConversation.conversation.id == secondID)
        #expect(again.brainConversation.conversations.map { $0.turns.count } == [2, 2])
    }

    @Test("switching during work routes output and Stop to the owning conversation and excludes work through cleanup")
    func switchDuringTurn() async throws {
        let fixture = try Fixture()
        let connections = Connections()
        let runner = HoldingRunner()
        let model = fixture.makeModel(connections: connections, runner: runner)
        let firstID = model.brainConversation.conversation.id
        model.askBrainConversation("First?")
        try await eventually { connections.made.first?.isPrompting == true }
        connections.last.send(.finish(.endTurn))
        try await eventually { !model.isAgentOperationActive }
        model.createBrainConversation()
        let secondID = model.brainConversation.conversation.id
        try await eventually { !model.isAgentOperationActive }
        connections.holdsClose = true
        model.askBrainConversation("Running?")
        try await eventually { connections.made.count == 2 && connections.last.isPrompting }
        let active = connections.last

        #expect(model.selectBrainConversation(firstID))
        #expect(model.brainConversation.conversation.id == firstID)
        #expect(model.brainConversation.isTurnActive)
        active.send(.event(.answerChunk("Owned answer.")))
        active.send(.event(.toolCall(id: "b", title: "Read for second", kind: "read", status: .completed)))
        try await eventually {
            model.brainConversation.conversations.first { $0.id == secondID }?.turns.last?.answer == "Owned answer."
        }
        #expect(model.brainConversation.conversation.turns.map(\.question) == ["First?"])
        #expect(model.createBrainConversation())
        let thirdID = model.brainConversation.conversation.id
        #expect(model.brainConversation.conversation.turns.isEmpty)
        #expect(model.brainConversation.conversation.sessionID == nil)
        #expect(!model.askBrainConversation("Concurrent?"))
        model.startBrainRun()
        #expect(runner.launchCount == 0)
        #expect(connections.made.count == 2)

        model.stopBrainConversationTurn()
        try await eventually { active.closeCount >= 1 }
        #expect(model.isAgentOperationActive)
        #expect(!model.askBrainConversation("During cleanup?"))
        model.startBrainRun()
        #expect(runner.launchCount == 0)
        active.releaseClose()
        try await eventually { !model.isAgentOperationActive }
        active.sendLate(.answerChunk(" Late."))
        await drainMainQueue()
        #expect(model.brainConversation.conversation.id == thirdID)
        #expect(model.brainConversation.conversation.turns.isEmpty)
        let stopped = try #require(model.brainConversation.conversations.first { $0.id == secondID }?.turns.last)
        #expect(stopped.answer == "Owned answer.")
        #expect(stopped.state == .incomplete(reason: nil))
        #expect(stopped.activity.contains { $0.title == "Read for second" })
        #expect(try fixture.store.lastSuccessfulRun(for: fixture.vault) == nil)

        let reopened = fixture.makeModel(connections: Connections())
        #expect(reopened.brainConversation.conversation.id == thirdID)
        #expect(reopened.brainConversation.conversations.count == 3)
        #expect(reopened.selectBrainConversation(secondID))
        #expect(reopened.brainConversation.conversation.turns.last == stopped)
    }

    @Test("selection before a turn starts cannot retarget its session, and returning during streaming keeps its context")
    func switchBeforeLaunch() async throws {
        let fixture = try Fixture()
        let connections = Connections()
        let model = try await finishedConversation(fixture, connections: connections)
        let first = model.brainConversation.conversation
        #expect(model.createBrainConversation())
        let secondID = model.brainConversation.conversation.id
        try await eventually { !model.isAgentOperationActive }

        #expect(model.askBrainConversation("Brand new?"))
        #expect(model.selectBrainConversation(first.id))
        try await eventually { connections.made.count == 2 && connections.last.isPrompting }
        #expect(connections.last.resumedSessions.isEmpty)
        #expect(connections.last.prompts == [[BrainConversationInstructions.text, "Brand new?"]])
        connections.last.send(.event(.answerChunk("Second only.")))
        try await eventually {
            model.brainConversation.conversations.first { $0.id == secondID }?.turns.last?.answer == "Second only."
        }
        #expect(model.brainConversation.conversation == first)
        #expect(model.selectBrainConversation(secondID))
        connections.last.send(.finish(.endTurn))
        try await eventually { !model.isAgentOperationActive }
        let secondSession = model.brainConversation.conversation.sessionID
        #expect(model.brainConversation.conversation.turns.map(\.answer) == ["Second only."])
        #expect(secondSession != first.sessionID)

        #expect(model.askBrainConversation("Same context?"))
        try await eventually { connections.last.prompts.count == 2 }
        #expect(connections.last.prompts.last == ["Same context?"])
        #expect(model.brainConversation.conversation.sessionID == secondSession)
        connections.last.send(.finish(.endTurn))
        try await eventually { !model.isAgentOperationActive }
    }

    @Test("idle session cleanup and Brain Run exclude all conversations while saved history and note editing remain available")
    func selectionAndBrainRun() async throws {
        let fixture = try Fixture()
        let connections = Connections()
        let runner = HoldingRunner()
        let model = fixture.makeModel(connections: connections, runner: runner)
        model.askBrainConversation("First?")
        try await eventually { connections.made.first?.isPrompting == true }
        connections.last.send(.finish(.endTurn))
        try await eventually { !model.isAgentOperationActive }
        let firstID = model.brainConversation.conversation.id
        let idle = connections.last
        idle.holdClose()
        #expect(model.createBrainConversation())
        try await eventually { idle.closeCount >= 1 }
        #expect(model.brainConversation.isConnectionClosing)
        #expect(!model.askBrainConversation("Too soon?"))
        model.startBrainRun()
        #expect(runner.launchCount == 0)
        #expect(model.selectBrainConversation(firstID))
        #expect(model.brainConversation.conversation.turns.first?.question == "First?")
        let note = try #require(model.openExistingNote(relativePath: "Plan.md"))
        note.text += "Local draft."
        #expect(note.hasUnsavedChanges)
        idle.releaseClose()
        try await eventually { !model.isAgentOperationActive && !model.brainConversation.isConnectionClosing }

        model.startBrainRun()
        try await eventually { runner.launchCount == 1 }
        #expect(model.createBrainConversation())
        #expect(!model.askBrainConversation("During Brain Run?"))
        #expect(model.brainConversation.refusal?.contains("Brain Run") == true)
        #expect(model.selectBrainConversation(firstID))
        #expect(!model.askBrainConversation("Still running?"))
        #expect(model.brainConversation.conversation.turns.count == 1)
        #expect(note.text.hasSuffix("Local draft."))
        #expect(try String(contentsOf: note.fileURL, encoding: .utf8) == "# Plan\n")
        model.cancelBrainRun()
        try await eventually { !model.isAgentOperationActive }
        #expect(try fixture.store.lastSuccessfulRun(for: fixture.vault) == nil)
    }

    @Test("multiple conversations stay in their Vault even when the streaming conversation is not selected on leaving")
    func multipleVaultIsolation() async throws {
        let fixture = try Fixture()
        let connections = Connections()
        let model = try await finishedConversation(fixture, connections: connections)
        let first = model.brainConversation.conversation
        model.createBrainConversation()
        let secondID = model.brainConversation.conversation.id
        try await eventually { !model.isAgentOperationActive }
        connections.holdsClose = true
        model.askBrainConversation("Private second?")
        try await eventually { connections.made.count == 2 && connections.last.isPrompting }
        let active = connections.last
        active.send(.event(.answerChunk("Second Vault-specific answer.")))
        try await eventually { model.brainConversation.conversation.turns.last?.answer == "Second Vault-specific answer." }
        model.selectBrainConversation(first.id)
        model.chooseVault(at: fixture.otherURL)
        try await eventually { active.closeCount >= 1 }
        active.sendLate(.answerChunk("Never cross Vaults."))
        await drainMainQueue()
        #expect(model.brainConversation.conversations.count == 1)
        #expect(model.brainConversation.conversation.turns.isEmpty)
        #expect(model.brainConversation.conversation.sessionID == nil)
        #expect(model.brainConversation.resumeFailure == nil)
        active.releaseClose()
        try await eventually { !model.isAgentOperationActive }

        connections.holdsClose = false
        model.askBrainConversation("Other Vault?")
        try await eventually { connections.made.count == 3 && connections.last.isPrompting }
        #expect(connections.last.resumedSessions.isEmpty)
        #expect(connections.last.vault == Vault(rootURL: fixture.otherURL))
        connections.last.send(.event(.answerChunk("Other only.")))
        connections.last.send(.finish(.endTurn))
        try await eventually { !model.isAgentOperationActive }
        let other = model.brainConversation.conversation

        model.chooseVault(at: fixture.rootURL)
        try await eventually { !model.isAgentOperationActive }
        #expect(model.brainConversation.conversation == first)
        #expect(model.brainConversation.conversations.count == 2)
        #expect(model.selectBrainConversation(secondID))
        #expect(model.brainConversation.conversation.turns.map(\.answer) == ["Second Vault-specific answer."])
        #expect(model.brainConversation.conversation.turns.last?.state == .incomplete(reason: nil))
        model.chooseVault(at: fixture.otherURL)
        #expect(model.brainConversation.conversations == [other])
    }

    @Test("legacy v1 single-conversation history stays selectable and continues its own session without replaying prompts")
    func legacyHistory() async throws {
        let fixture = try Fixture()
        let id = UUID()
        try FileManager.default.createDirectory(at: fixture.conversationStoreURL, withIntermediateDirectories: true)
        try """
        {
          "version": 1, "vaultPath": "\(fixture.vault.rootURL.path(percentEncoded: false))",
          "currentConversationID": "\(id.uuidString)",
          "conversations": [{
            "id": "\(id.uuidString)", "updatedAt": "2025-10-18T05:00:00Z",
            "acpSessionID": "legacy-session", "sessionHasInstructions": true,
            "turns": [{
              "id": "\(UUID().uuidString)", "question": "Legacy question?", "answer": "Legacy answer.",
              "state": {"kind": "completed"}, "startedAt": "2025-10-18T05:00:00Z",
              "activity": [{"id": "old", "title": "Legacy read", "kind": "tool", "status": "completed"}]
            }]
          }]
        }
        """.write(to: fixture.conversationStore.fileURL(for: fixture.vault), atomically: true, encoding: .utf8)
        let model = fixture.makeModel(connections: Connections())
        #expect(model.brainConversation.conversation.id == id)
        #expect(model.createBrainConversation())
        let connections = Connections()
        let reopened = fixture.makeModel(connections: connections)
        #expect(reopened.brainConversation.conversations.count == 2)
        #expect(reopened.selectBrainConversation(id))
        #expect(reopened.brainConversation.conversation.turns.map(\.answer) == ["Legacy answer."])
        #expect(reopened.brainConversation.conversation.turns[0].activity.first?.title == "Legacy read")
        #expect(reopened.askBrainConversation("Legacy follow-up?"))
        try await eventually { connections.made.first?.isPrompting == true }
        #expect(connections.last.resumedSessions == ["legacy-session"])
        #expect(connections.last.prompts == [["Legacy follow-up?"]])
        connections.last.send(.finish(.endTurn))
        try await eventually { !reopened.isAgentOperationActive }
        #expect(reopened.brainConversation.conversation.turns.count == 2)
    }

    @Test("resume failures and explicit context recovery belong only to the selected conversation")
    func scopedResumeFailure() async throws {
        let fixture = try Fixture()
        let original = try await finishedConversation(fixture, connections: Connections())
        let first = original.brainConversation.conversation
        let connections = Connections()
        connections.resumeError = .sessionUnavailable("missing first session")
        let model = fixture.makeModel(connections: connections)
        model.askBrainConversation("Follow up?")
        try await eventually { !model.isAgentOperationActive }
        #expect(model.brainConversation.resumeFailure != nil)
        model.createBrainConversation()
        let secondID = model.brainConversation.conversation.id
        #expect(model.brainConversation.resumeFailure == nil)
        model.askBrainConversation("Unrelated?")
        try await eventually { connections.made.count == 2 && connections.last.isPrompting }
        connections.last.send(.finish(.endTurn))
        try await eventually { !model.isAgentOperationActive }
        let second = model.brainConversation.conversation
        model.selectBrainConversation(first.id)
        #expect(model.brainConversation.resumeFailure != nil)
        model.continueBrainConversationWithoutContext()
        #expect(model.brainConversation.conversation.sessionID == nil)
        #expect(model.brainConversation.conversation.turns.first == first.turns.first)
        #expect(model.selectBrainConversation(secondID))
        #expect(model.brainConversation.conversation == second)
        #expect(!model.brainConversation.contextWasDiscarded)
        #expect(model.brainConversation.resumeFailure == nil)
        try await eventually { !model.isAgentOperationActive }
    }

    @Test("late events from an ended turn cannot restore a discarded session when returning to its conversation")
    func lateEventsDoNotRestoreContext() async throws {
        let fixture = try Fixture()
        let connections = Connections()
        let model = try await finishedConversation(fixture, connections: connections)
        let firstID = model.brainConversation.conversation.id
        let ended = connections.last
        model.createBrainConversation()
        try await eventually { !model.isAgentOperationActive }
        model.selectBrainConversation(firstID)
        connections.resumeError = .sessionUnavailable("missing session")
        model.askBrainConversation("Failed resume?")
        try await eventually { !model.isAgentOperationActive }
        model.continueBrainConversationWithoutContext()
        #expect(model.brainConversation.conversation.sessionID == nil)
        let transcript = model.brainConversation.conversation.turns
        ended.sendLate(.answerChunk("Late old session."))
        await drainMainQueue()
        #expect(model.brainConversation.conversation.sessionID == nil)
        #expect(!model.brainConversation.conversation.sessionHasInstructions)
        #expect(model.brainConversation.conversation.turns == transcript)
    }

    @Test("a new app run shows the saved transcript and activity of the Vault")
    func reopenShowsHistory() async throws {
        let fixture = try Fixture()
        let first = try await finishedConversation(fixture, connections: Connections())
        let saved = first.brainConversation.conversation

        let reopened = fixture.makeModel(connections: Connections())

        let conversation = reopened.brainConversation.conversation
        #expect(conversation.id == saved.id)
        #expect(conversation.turns.map(\.question) == ["Who keeps the codeword?"])
        #expect(conversation.turns[0].answer == "Alice.")
        #expect(conversation.turns[0].state == .completed)
        #expect(conversation.turns[0].activity == saved.turns[0].activity)
        #expect(conversation.sessionID == saved.sessionID)
        #expect(reopened.brainConversation.historyFailure == nil)
        #expect(!reopened.isAgentOperationActive)
    }

    @Test("a follow-up after a restart resumes the saved session, resends no instructions and no earlier prompt")
    func continueAfterRestart() async throws {
        let fixture = try Fixture()
        let first = try await finishedConversation(fixture, connections: Connections())
        let session = try #require(first.brainConversation.conversation.sessionID)

        let connections = Connections()
        let reopened = fixture.makeModel(connections: connections)
        #expect(reopened.askBrainConversation("And Bob?"))
        try await eventually { connections.made.first?.isPrompting == true }
        #expect(connections.last.resumedSessions == [session])
        #expect(connections.last.prompts == [["And Bob?"]])
        connections.last.send(.event(.answerChunk("Bob too.")))
        connections.last.send(.finish(.endTurn))
        try await eventually { !reopened.isAgentOperationActive }

        let turns = reopened.brainConversation.conversation.turns
        #expect(turns.map(\.question) == ["Who keeps the codeword?", "And Bob?"])
        #expect(turns.map(\.answer) == ["Alice.", "Bob too."])
        #expect(reopened.brainConversation.conversation.sessionID == session)

        let again = fixture.makeModel(connections: Connections())
        #expect(again.brainConversation.conversation.turns.count == 2)
    }

    @Test("a turn that was streaming when Notess died comes back incomplete and interrupted, with its partial answer")
    func crashKeepsPartialAnswer() async throws {
        let fixture = try Fixture()
        let connections = Connections()
        let model = fixture.makeModel(connections: connections)
        model.askBrainConversation("Long?")
        try await eventually { connections.made.first?.isPrompting == true }
        connections.last.send(.event(.answerChunk("half")))
        try await eventually {
            (try? fixture.conversationStore.load(for: fixture.vault))??.turns.first?.answer == "half"
        }

        let reopened = fixture.makeModel(connections: Connections())

        let turn = reopened.brainConversation.conversation.turns[0]
        #expect(turn.answer == "half")
        #expect(turn.state == .incomplete(reason: BrainConversation.interruptedReason))
        #expect(!reopened.brainConversation.isTurnActive)
        connections.last.send(.finish(.cancelled))
    }

    @Test("history that cannot be read is reported, blocks asking, is not overwritten, and is set aside only on request")
    func unreadableHistory() async throws {
        let fixture = try Fixture()
        _ = try await finishedConversation(fixture, connections: Connections())
        let file = fixture.conversationStore.fileURL(for: fixture.vault)
        try "{ broken".write(to: file, atomically: true, encoding: .utf8)

        let connections = Connections()
        let model = fixture.makeModel(connections: connections)

        #expect(model.brainConversation.historyFailure != nil)
        #expect(model.brainConversation.conversation.turns.isEmpty)
        #expect(!model.askBrainConversation("Q?"))
        #expect(connections.made.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "{ broken")

        model.startNewBrainConversationAfterUnreadableHistory()
        #expect(model.brainConversation.historyFailure == nil)
        let aside = try FileManager.default.contentsOfDirectory(atPath: fixture.conversationStoreURL.path(percentEncoded: false))
            .filter { $0.contains("unreadable") }
        #expect(aside.count == 1)
        #expect(model.askBrainConversation("Q?"))
        try await eventually { connections.made.first?.isPrompting == true }
        connections.last.send(.finish(.endTurn))
        try await eventually { !model.isAgentOperationActive }
        #expect(try fixture.conversationStore.load(for: fixture.vault)?.turns.map(\.question) == ["Q?"])
    }

    @Test("a history that cannot be saved is shown as such, and the conversation still works")
    func saveFailure() async throws {
        let fixture = try Fixture()
        try FileManager.default.createDirectory(at: fixture.storeURL, withIntermediateDirectories: true)
        try "in the way".write(to: fixture.conversationStoreURL, atomically: true, encoding: .utf8)
        let connections = Connections()
        let model = fixture.makeModel(connections: connections)

        model.askBrainConversation("Q?")
        try await eventually { connections.made.first?.isPrompting == true }
        #expect(model.brainConversation.persistenceFailure != nil)
        connections.last.send(.event(.answerChunk("A")))
        connections.last.send(.finish(.endTurn))
        try await eventually { !model.isAgentOperationActive }
        #expect(model.brainConversation.conversation.turns[0].answer == "A")
        #expect(model.brainConversation.persistenceFailure != nil)
    }

    @Test("a saved session that cannot be loaded fails the turn explicitly, keeps the history, and continuing without context starts a new session")
    func sessionLoadFailure() async throws {
        let fixture = try Fixture()
        _ = try await finishedConversation(fixture, connections: Connections())

        let connections = Connections()
        connections.resumeError = .sessionUnavailable("unknown session")
        let model = fixture.makeModel(connections: connections)
        model.askBrainConversation("And Bob?")
        try await eventually { model.brainConversation.resumeFailure != nil && !model.isAgentOperationActive }

        var turns = model.brainConversation.conversation.turns
        #expect(turns.map(\.question) == ["Who keeps the codeword?", "And Bob?"])
        #expect(turns[0].answer == "Alice.")
        guard case .failed = turns[1].state else {
            Issue.record("expected a failed turn, got \(turns[1].state)")
            return
        }
        #expect(model.brainConversation.conversation.sessionID != nil)

        model.continueBrainConversationWithoutContext()
        #expect(model.brainConversation.resumeFailure == nil)
        #expect(model.brainConversation.conversation.sessionID == nil)
        connections.resumeError = nil
        let before = connections.made.count
        #expect(model.askBrainConversation("Fresh?"))
        try await eventually { connections.made.count > before && connections.last.isPrompting }
        #expect(connections.last.resumedSessions.isEmpty)
        #expect(connections.last.prompts == [[BrainConversationInstructions.text, "Fresh?"]])
        connections.last.send(.finish(.endTurn))
        try await eventually { !model.isAgentOperationActive }
        turns = model.brainConversation.conversation.turns
        #expect(turns.first?.question == "Who keeps the codeword?")
        #expect(turns.last?.state == .completed)
    }

    @Test("history and session belong to their Vault; leaving a Vault saves it and its late events touch nothing else")
    func perVaultIsolation() async throws {
        let fixture = try Fixture()
        let connections = Connections()
        connections.holdsClose = true
        let model = fixture.makeModel(connections: connections)
        model.askBrainConversation("Q")
        try await eventually { connections.made.first?.isPrompting == true }
        let old = connections.last
        old.send(.event(.answerChunk("old")))
        try await eventually { model.brainConversation.conversation.turns.first?.answer == "old" }

        model.chooseVault(at: fixture.otherURL)
        try await eventually { old.closeCount >= 1 }
        old.sendLate(.answerChunk(" late"))
        await drainMainQueue()
        old.releaseClose()
        try await eventually { !model.isAgentOperationActive }

        let saved = try #require(try fixture.conversationStore.load(for: fixture.vault))
        #expect(saved.turns[0].answer == "old")
        #expect(saved.turns[0].state == .incomplete(reason: nil))
        #expect(try fixture.conversationStore.load(for: Vault(rootURL: fixture.otherURL)) == nil)
        #expect(model.brainConversation.conversation.turns.isEmpty)
        #expect(model.brainConversation.conversation.sessionID == nil)

        model.chooseVault(at: fixture.rootURL)
        #expect(model.brainConversation.conversation.turns.map(\.answer) == ["old"])
        #expect(model.brainConversation.conversation.sessionID == saved.sessionID)
    }

    @Test("instructions the session never received are sent after a restart; an exit does not erase the saved session")
    func instructionsNotMarkedDeliveredBeforeThePrompt() async throws {
        let fixture = try Fixture()
        let connections = Connections()
        let model = fixture.makeModel(connections: connections)
        model.askBrainConversation("Q?")
        try await eventually { connections.made.first?.isPrompting == true }
        connections.last.send(.fail(.exited(status: 1, detail: "early")))
        try await eventually { !model.isAgentOperationActive }

        let saved = try #require(try fixture.conversationStore.load(for: fixture.vault))
        #expect(saved.sessionID != nil)
        #expect(!saved.sessionHasInstructions)

        let next = Connections()
        let reopened = fixture.makeModel(connections: next)
        reopened.askBrainConversation("Again?")
        try await eventually { next.made.first?.isPrompting == true }
        #expect(next.last.resumedSessions == [saved.sessionID!])
        #expect(next.last.prompts == [[BrainConversationInstructions.text, "Again?"]])
        next.last.send(.finish(.endTurn))
        try await eventually { !reopened.isAgentOperationActive }
        #expect(try fixture.conversationStore.load(for: fixture.vault)?.sessionHasInstructions == true)
    }

    @Test("quitting saves the stopped turn so the next run shows it")
    func quitSaves() async throws {
        let fixture = try Fixture()
        let connections = Connections()
        let model = fixture.makeModel(connections: connections)
        model.askBrainConversation("Q")
        try await eventually { connections.made.first?.isPrompting == true }
        connections.last.send(.event(.answerChunk("part")))
        try await eventually { model.brainConversation.conversation.turns.first?.answer == "part" }

        await model.terminateAgentOperations()

        let saved = try #require(try fixture.conversationStore.load(for: fixture.vault))
        #expect(saved.turns[0].answer == "part")
        #expect(saved.turns[0].state == .incomplete(reason: nil))
    }
}

@MainActor
private final class Flag {
    var value = false
}
