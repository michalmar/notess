import Foundation
import Testing
@testable import NotessCore

private struct Fixture {
    let directory: URL
    let vault: Vault
    let otherVault: Vault
    let store: BrainConversationStore
    let date = Date(timeIntervalSince1970: 1_760_765_000)

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "NotessBrainConversationStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        directory = base.appending(path: "history", directoryHint: .isDirectory)
        vault = Vault(rootURL: base.appending(path: "vault", directoryHint: .isDirectory))
        otherVault = Vault(rootURL: base.appending(path: "other", directoryHint: .isDirectory))
        store = BrainConversationStore(directoryURL: directory)
    }

    var file: URL { store.fileURL(for: vault) }

    func writeRaw(_ text: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    func conversation() -> BrainConversation {
        var conversation = BrainConversation()
        conversation.attach(sessionID: "session-1", hasInstructions: true)
        let first = conversation.begin(question: "Who?", at: date)!
        conversation.apply(.toolCall(id: "t1", title: "Read Alice.md", kind: "read", status: .completed), to: first)
        conversation.apply(.permissionAllowed(title: "Run grep", option: "Allow once"), to: first)
        conversation.note("Spouštím Agenta", in: first)
        conversation.apply(.answerChunk("Alice."), to: first)
        conversation.finish(first, stopReason: .endTurn, at: date)
        return conversation
    }
}

@Suite("Brain Conversation store")
struct BrainConversationStoreTests {
    @Test("a saved conversation round-trips with its session, transcript and activity")
    func roundTrip() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let conversation = fixture.conversation()

        try fixture.store.save(conversation, at: fixture.date, for: fixture.vault)
        let loaded = try #require(try fixture.store.load(for: fixture.vault))

        #expect(loaded.id == conversation.id)
        #expect(loaded.sessionID == "session-1")
        #expect(loaded.sessionHasInstructions)
        #expect(loaded.turns.count == 1)
        #expect(loaded.turns[0].question == "Who?")
        #expect(loaded.turns[0].answer == "Alice.")
        #expect(loaded.turns[0].state == .completed)
        #expect(loaded.turns[0].activity == conversation.turns[0].activity)
    }

    @Test("a Vault without history has no conversation")
    func noHistory() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        #expect(try fixture.store.load(for: fixture.vault) == nil)
    }

    @Test("history is kept per Vault")
    func perVault() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.store.save(fixture.conversation(), at: fixture.date, for: fixture.vault)

        #expect(try fixture.store.load(for: fixture.otherVault) == nil)
        #expect(fixture.store.fileURL(for: fixture.vault) != fixture.store.fileURL(for: fixture.otherVault))
    }

    @Test("turns still running when saved come back incomplete and interrupted")
    func activeTurnsAreInterrupted() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var conversation = BrainConversation()
        let turn = conversation.begin(question: "Long?", at: fixture.date)!
        conversation.apply(.answerChunk("half"), to: turn)
        try fixture.store.save(conversation, at: fixture.date, for: fixture.vault)

        let loaded = try #require(try fixture.store.load(for: fixture.vault))
        #expect(loaded.turns[0].answer == "half")
        #expect(loaded.turns[0].state == .incomplete(reason: BrainConversation.interruptedReason))
        #expect(!loaded.turns[0].state.isActive)
    }

    @Test("saving again updates the conversation instead of adding another")
    func upsert() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var conversation = fixture.conversation()
        try fixture.store.save(conversation, at: fixture.date, for: fixture.vault)
        let second = conversation.begin(question: "And?", at: fixture.date)!
        conversation.apply(.answerChunk("Bob."), to: second)
        conversation.finish(second, stopReason: .endTurn, at: fixture.date)
        try fixture.store.save(conversation, at: fixture.date, for: fixture.vault)

        let loaded = try #require(try fixture.store.load(for: fixture.vault))
        #expect(loaded.turns.map(\.question) == ["Who?", "And?"])
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.file)) as? [String: Any]
        #expect((json?["conversations"] as? [Any])?.count == 1)
        #expect(json?["version"] as? Int == BrainConversationStore.currentVersion)
    }

    @Test("other conversations in the file survive a save and the current one is chosen by id")
    func keepsOtherConversations() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let kept = fixture.conversation()
        try fixture.store.save(kept, at: fixture.date, for: fixture.vault)
        var second = BrainConversation()
        let turn = second.begin(question: "New?", at: fixture.date)!
        second.finish(turn, stopReason: .endTurn, at: fixture.date)
        try fixture.store.save(second, at: fixture.date, for: fixture.vault)

        let loaded = try #require(try fixture.store.load(for: fixture.vault))
        #expect(loaded.id == second.id)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.file)) as? [String: Any]
        #expect((json?["conversations"] as? [Any])?.count == 2)
    }

    @Test("unknown fields are ignored and missing optional ones get defaults, so older and newer activity loads")
    func toleratesFieldChanges() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let id = UUID()
        let turnID = UUID()
        try fixture.writeRaw("""
        {
          "version": 1,
          "futureTopLevel": {"a": 1},
          "vaultPath": "\(fixture.vault.rootURL.path(percentEncoded: false))",
          "currentConversationID": "\(id.uuidString)",
          "conversations": [{
            "id": "\(id.uuidString)",
            "updatedAt": "2025-10-18T05:00:00Z",
            "title": "future field",
            "turns": [{
              "id": "\(turnID.uuidString)",
              "question": "Q",
              "state": {"kind": "completed"},
              "startedAt": "2025-10-18T05:00:00Z",
              "activity": [
                {"id": "a", "title": "Read", "kind": "tool", "details": {"input": {"path": "x"}}},
                {"id": "b", "title": "Note", "kind": "notice"}
              ]
            }]
          }]
        }
        """)

        let loaded = try #require(try fixture.store.load(for: fixture.vault))
        #expect(loaded.sessionID == nil)
        #expect(!loaded.sessionHasInstructions)
        #expect(loaded.turns[0].answer.isEmpty)
        #expect(loaded.turns[0].activity.map(\.id) == ["a", "b"])
    }

    @Test("malformed history is reported, never read as empty, and never overwritten")
    func malformedIsNotOverwritten() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeRaw("{ not json")

        #expect(throws: BrainConversationStoreError.self) { try fixture.store.load(for: fixture.vault) }
        #expect(throws: BrainConversationStoreError.self) {
            try fixture.store.save(fixture.conversation(), at: fixture.date, for: fixture.vault)
        }
        #expect(try String(contentsOf: fixture.file, encoding: .utf8) == "{ not json")
    }

    @Test("history written by a newer version is refused with its own error")
    func newerVersion() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeRaw(#"{"version": 99, "somethingNew": true}"#)

        do {
            _ = try fixture.store.load(for: fixture.vault)
            Issue.record("expected an unsupported version")
        } catch {
            guard case .unsupportedVersion(99, _) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
    }

    @Test("a file that names another Vault is refused")
    func otherVaultFile() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeRaw(#"{"version": 1, "vaultPath": "/somewhere/else", "conversations": []}"#)

        do {
            _ = try fixture.store.load(for: fixture.vault)
            Issue.record("expected another Vault")
        } catch {
            guard case .otherVault = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
    }

    @Test("unreadable history can be set aside deliberately and a new conversation then saves")
    func setAside() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeRaw("garbage")

        let aside = try #require(try fixture.store.setUnreadableHistoryAside(for: fixture.vault, at: fixture.date))
        #expect(try String(contentsOf: aside, encoding: .utf8) == "garbage")
        #expect(try fixture.store.load(for: fixture.vault) == nil)
        try fixture.store.save(fixture.conversation(), at: fixture.date, for: fixture.vault)
        #expect(try fixture.store.load(for: fixture.vault) != nil)
    }

    @Test("an unwritable location is a write failure")
    func writeFailure() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(
            at: fixture.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "file".write(to: fixture.directory, atomically: true, encoding: .utf8)

        do {
            try fixture.store.save(fixture.conversation(), at: fixture.date, for: fixture.vault)
            Issue.record("expected a write failure")
        } catch {
            guard case .writeFailed = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
    }
}
