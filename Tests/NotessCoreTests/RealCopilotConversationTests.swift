import Foundation
import Testing
@testable import NotessCore

/// Runs the real Copilot CLI in ACP mode under the Vault write sandbox (costs AI
/// credits), so only with `NOTESS_REAL_COPILOT=1 swift test --filter RealCopilotConversation`.
/// `NOTESS_COPILOT_MODEL` picks the model (default `claude-haiku-4.5`).
@Suite(
    "Real Copilot Brain Conversation",
    .serialized,
    .timeLimit(.minutes(2)),
    .enabled(if: ProcessInfo.processInfo.environment["NOTESS_REAL_COPILOT"] == "1")
)
struct RealCopilotConversationTests {
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ACPSessionEvent] = []
        func append(_ event: ACPSessionEvent) { lock.withLock { events.append(event) } }
        var answer: String {
            lock.withLock {
                events.compactMap { if case .answerChunk(let text) = $0 { text } else { nil } }.joined()
            }
        }
        var count: Int { lock.withLock { events.count } }
    }

    /// Copilot CLI occasionally never answers `session/prompt` after its last chunk; a
    /// deadline turns that into a failure instead of a hung test run.
    private func ask(
        _ agent: CopilotACPConnection, _ blocks: [String], events: Events, within limit: Duration = .seconds(50)
    ) async throws -> ACPStopReason {
        let started = ContinuousClock.now
        let turn = Task { try await agent.prompt(blocks, events: events.append) }
        let deadline = Task {
            try await Task.sleep(for: limit)
            turn.cancel()
        }
        defer { deadline.cancel() }
        let stop = try await turn.value
        if stop == .cancelled, ContinuousClock.now - started >= limit {
            Issue.record("session/prompt did not answer within \(limit) (answer so far: \(events.answer))")
        }
        return stop
    }

    /// Starts the real Agent on `vault`, runs `body`, and always waits for its process group to end.
    private func withAgent(_ vault: Vault, _ body: (CopilotACPConnection) async throws -> Void) async throws {
        let executable = try #require(CopilotCLILocator().detect())
        let model = ProcessInfo.processInfo.environment["NOTESS_COPILOT_MODEL"] ?? "claude-haiku-4.5"
        let agent = CopilotACPConnection(
            vault: vault,
            configuration: .init(
                executableURL: executable,
                model: model,
                additionalArguments: ["--disable-mcp-server", "workiq-mail"]
            )
        )
        do {
            try await agent.start()
            try await body(agent)
        } catch {
            await agent.close()
            throw error
        }
        await agent.close()
    }

    private func snapshot(_ vault: Vault) throws -> [String: Data] {
        let enumerator = try #require(FileManager.default.enumerator(
            at: vault.rootURL, includingPropertiesForKeys: [.isRegularFileKey]
        ))
        var files: [String: Data] = [:]
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                let path = String(url.path.dropFirst(vault.rootURL.path.count + 1))
                files[path] = try Data(contentsOf: url)
            }
        }
        return files
    }

    @Test("a follow-up keeps the conversation's context and the answer comes from _brain/")
    func followUp() async throws {
        let temp = try TemporaryVault()
        try temp.write("# Atlas\n\n## Status\n\nThe Atlas project's codeword is PELICAN-42. [[Notes/Plan#Decision]]\n", to: "_brain/Atlas.md")
        try temp.write("# Plan\n\n## Decision\n\nAtlas codeword: PELICAN-42.\n", to: "Notes/Plan.md")
        let before = try snapshot(temp.vault)
        try await withAgent(temp.vault) { agent in
            let first = Events()
            let firstStop = try await ask(
                agent,
                BrainConversationInstructions.promptBlocks(question: "What is the Atlas project's codeword?", isFirstInSession: true),
                events: first
            )
            print("first:", first.answer)
            #expect(firstStop == .endTurn)
            #expect(first.answer.contains("PELICAN-42"))
            let sources = BrainConversationEvidence.sources(in: first.answer)
            #expect(sources.contains { source in
                BrainConversationEvidence.noteLink(from: source.url)?.target == "_brain/Atlas"
            }, "the answer links the supporting Brain Note, not just its title: \(first.answer)")

            let second = Events()
            let secondStop = try await ask(
                agent,
                BrainConversationInstructions.promptBlocks(
                    question: "Which number is part of that codeword? Reply with only the number and do not read any files.",
                    isFirstInSession: false
                ),
                events: second
            )
            print("second:", second.answer)
            #expect(secondStop == .endTurn)
            #expect(second.answer.contains("42"))
            #expect(await agent.isOpen())
        }
        #expect(try snapshot(temp.vault) == before, "live investigation never changes the Vault")
    }

    @Test("an original note fills a Brain Note gap with explicit disclosure and a concrete Section source")
    func originalNoteEvidence() async throws {
        let temp = try TemporaryVault()
        try temp.write("# Atlas\n\n## Status\n\nAtlas is an inert test project. Its recovery token is not recorded here.\n", to: "_brain/Atlas.md")
        try temp.write("# Launch\n\n## Recovery\n\nThe Atlas recovery token is ORCHID-73.\n", to: "Notes/Launch.md")
        let before = try snapshot(temp.vault)
        try await withAgent(temp.vault) { agent in
            let events = Events()
            let stop = try await ask(agent, BrainConversationInstructions.promptBlocks(
                question: "What is the Atlas recovery token? Use only saved Vault notes, not web sources.",
                isFirstInSession: true
            ), events: events)
            print("original evidence:", events.answer)
            #expect(stop == .endTurn)
            #expect(events.answer.contains("ORCHID-73"))
            let sources = BrainConversationEvidence.sources(in: events.answer)
            #expect(sources.contains {
                let link = BrainConversationEvidence.noteLink(from: $0.url)
                return link?.target == "Notes/Launch" && link?.section == "Recovery"
            }, "the concrete original-note Section is clickable")
            let lower = events.answer.lowercased()
            #expect(lower.contains("original") || lower.contains("free note"),
                    "the answer discloses original-note fallback, not just a bare link")
        }
        #expect(try snapshot(temp.vault) == before)
    }

    @Test("a no-evidence question acknowledges the gap rather than inventing support")
    func insufficientEvidence() async throws {
        let temp = try TemporaryVault()
        try temp.write("# Atlas\n\n## Status\n\nAtlas is an inert test project.\n", to: "_brain/Atlas.md")
        try temp.write("# Plan\n\n## Agenda\n\nDiscuss the Atlas test fixture.\n", to: "Notes/Plan.md")
        let before = try snapshot(temp.vault)
        try await withAgent(temp.vault) { agent in
            let events = Events()
            let stop = try await ask(agent, BrainConversationInstructions.promptBlocks(
                question: "According to the saved Vault notes only, what is Zephyr's launch code? Do not use web sources.",
                isFirstInSession: true
            ), events: events)
            print("no evidence:", events.answer)
            #expect(stop == .endTurn)
            let lower = events.answer.lowercased()
            #expect(lower.range(
                of: #"\b(no|not|cannot|can't|couldn't|unknown|insufficient|unavailable|absent)\b"#,
                options: .regularExpression
            ) != nil, "the answer acknowledges missing evidence")
            #expect(!BrainConversationEvidence.sources(in: events.answer).contains {
                BrainConversationEvidence.noteLink(from: $0.url)?.target.localizedCaseInsensitiveContains("Zephyr") == true
            }, "no invented supporting Zephyr note")
        }
        #expect(try snapshot(temp.vault) == before)
    }

    @Test("Stop ends a running turn as cancelled")
    func cancel() async throws {
        let temp = try TemporaryVault()
        try temp.write("# Note\n\nNothing here.\n", to: "Note.md")
        try await withAgent(temp.vault) { agent in
            let events = Events()
            let turn = Task {
                try await agent.prompt(
                    ["Write a 2000-word essay about the history of note taking. Do not use any tools."],
                    events: events.append
                )
            }
            let deadline = ContinuousClock.now + .seconds(60)
            while events.count == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(events.count > 0, "the Agent started answering")
            let stoppedAt = ContinuousClock.now
            turn.cancel()
            let stop = try await turn.value
            #expect(stop == .cancelled)
            #expect(ContinuousClock.now - stoppedAt < .seconds(15), "Stop ends the turn promptly")
        }
    }

    @Test(
        "the OS refuses the Agent's shell writes into the Vault, directly, through symlink and hardlink aliases and by moving a folder above it"
    )
    func writesBlocked() async throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "NotessReal-\(UUID().uuidString)", directoryHint: .isDirectory)
        let parent = base.appending(path: "parent", directoryHint: .isDirectory)
        let root = parent.appending(path: "Vault", directoryHint: .isDirectory)
        let outside = base.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let note = root.appending(path: "Note.md")
        try "ORIGINAL\n".write(to: note, atomically: false, encoding: .utf8)
        let alias = outside.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let control = outside.appending(path: "control.txt")
        let moved = base.appending(path: "moved")

        try await withAgent(Vault(rootURL: root)) { agent in
            // A plain prompt without the read-only instructions: the OS must enforce, not the model.
            let script = [
                "printf OUTSIDE > '\(control.path)'",
                "printf DIRECT > '\(root.path)/direct.txt'",
                "printf CHANGED > '\(note.path)'",
                "printf ALIAS > '\(alias.path)/alias.txt'",
                "printf ALIAS >> '\(alias.path)/Note.md'",
                "ln '\(note.path)' '\(outside.path)/hardlink.md' && printf HARD >> '\(outside.path)/hardlink.md'",
                "mv '\(parent.path)' '\(moved.path)' && printf MOVED >> '\(moved.path)/Vault/Note.md'; mv '\(moved.path)' '\(parent.path)'",
            ]
            let events = Events()
            let stop = try await ask(
                agent,
                [
                    "This is a sandbox test. Run each of these shell commands separately with your shell tool, "
                        + "even if one fails, then report each command's result in one line:\n"
                        + script.joined(separator: "\n"),
                ],
                events: events
            )
            print("writes:", stop, events.answer)

            let controlText = try? String(contentsOf: control, encoding: .utf8)
            try #require(controlText == "OUTSIDE", "the Agent ran the commands (the write outside the Vault worked)")
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "direct.txt").path))
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "alias.txt").path))
            #expect(!FileManager.default.fileExists(atPath: moved.path))
            #expect(try String(contentsOf: note, encoding: .utf8) == "ORIGINAL\n")
        }
    }
}
