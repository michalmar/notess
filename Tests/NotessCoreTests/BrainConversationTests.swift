import Foundation
import Testing
@testable import NotessCore

@Suite("Brain Conversation model")
struct BrainConversationTests {
    private let start = Date(timeIntervalSince1970: 1_000)
    private let end = Date(timeIntervalSince1970: 1_042)

    @Test("a turn streams its answer and activity and completes on end_turn")
    func streamsAndCompletes() throws {
        var conversation = BrainConversation()
        let turnBegun = conversation.begin(question: "Who is Alice?", at: start)
        let turn = try #require(turnBegun)

        conversation.apply(.toolCall(id: "1", title: "Read _brain/Alice.md", kind: "read", status: .pending), to: turn)
        conversation.apply(.answerChunk("Alice "), to: turn)
        conversation.apply(.toolCallUpdate(id: "1", title: nil, status: .completed), to: turn)
        conversation.apply(.permissionAllowed(title: "Run grep", option: "Allow once"), to: turn)
        conversation.apply(.answerChunk("keeps the codeword."), to: turn)
        #expect(conversation.activeTurn?.id == turn)
        conversation.finish(turn, stopReason: .endTurn, at: end)

        let result = try #require(conversation.turns.first)
        #expect(result.answer == "Alice keeps the codeword.")
        #expect(result.state == .completed)
        #expect(result.finishedAt == end)
        #expect(result.activity.map(\.title) == ["Read _brain/Alice.md", "Run grep"])
        #expect(result.activity[0].kind == .tool(kind: "read", status: .completed))
        #expect(result.activity[1].kind == .permission(option: "Allow once"))
        #expect(conversation.activeTurn == nil)
    }

    @Test("only one turn runs at a time; a follow-up starts once the previous one ends")
    func oneTurnAtATime() throws {
        var conversation = BrainConversation()
        let firstBegun = conversation.begin(question: "one", at: start)
        let first = try #require(firstBegun)
        #expect(conversation.begin(question: "two", at: start) == nil)

        conversation.finish(first, stopReason: .endTurn, at: end)
        let secondBegun = conversation.begin(question: "two", at: end)
        let second = try #require(secondBegun)

        #expect(conversation.turns.map(\.question) == ["one", "two"])
        #expect(conversation.activeTurn?.id == second)
    }

    @Test("events for an ended or unknown turn are ignored")
    func staleEventsIgnored() throws {
        var conversation = BrainConversation()
        let turnBegun = conversation.begin(question: "q", at: start)
        let turn = try #require(turnBegun)
        conversation.apply(.answerChunk("kept"), to: turn)
        conversation.finish(turn, stopReason: .endTurn, at: end)

        conversation.apply(.answerChunk(" late"), to: turn)
        conversation.apply(.answerChunk("other"), to: UUID())
        conversation.fail(turn, message: "late failure", at: end)

        #expect(conversation.turns[0].answer == "kept")
        #expect(conversation.turns[0].state == .completed)
    }

    @Test("a stopped turn keeps its partial answer and is marked incomplete, even if the Agent says end_turn")
    func stopMarksIncomplete() throws {
        var conversation = BrainConversation()
        let stoppedBegun = conversation.begin(question: "q", at: start)
        let stopped = try #require(stoppedBegun)
        conversation.apply(.answerChunk("partial"), to: stopped)
        conversation.markStopping(stopped)
        #expect(conversation.turns[0].state == .stopping)
        #expect(conversation.begin(question: "again", at: start) == nil)
        conversation.finish(stopped, stopReason: .endTurn, at: end)

        #expect(conversation.turns[0].answer == "partial")
        #expect(conversation.turns[0].state == .incomplete(reason: nil))

        let cancelledBegun = conversation.begin(question: "q2", at: end)
        let cancelled = try #require(cancelledBegun)
        conversation.finish(cancelled, stopReason: .cancelled, at: end)
        #expect(conversation.turns[1].state == .incomplete(reason: nil))

        let killedBegun = conversation.begin(question: "q3", at: end)
        let killed = try #require(killedBegun)
        conversation.stop(killed, at: end)
        #expect(conversation.turns[2].state == .incomplete(reason: nil))
    }

    @Test("stop reasons other than end_turn leave the answer incomplete with a reason")
    func otherStopReasons() throws {
        for reason in [ACPStopReason.maxTokens, .maxTurnRequests, .refusal, .other("weird")] {
            var conversation = BrainConversation()
            let turnBegun = conversation.begin(question: "q", at: start)
        let turn = try #require(turnBegun)
            conversation.finish(turn, stopReason: reason, at: end)
            guard case .incomplete(let text) = conversation.turns[0].state else {
                Issue.record("\(reason) did not leave the turn incomplete")
                continue
            }
            #expect(text?.isEmpty == false)
        }
    }

    @Test("a failure is an error state, distinct from an answer")
    func failure() throws {
        var conversation = BrainConversation()
        let turnBegun = conversation.begin(question: "q", at: start)
        let turn = try #require(turnBegun)
        conversation.apply(.answerChunk("half"), to: turn)
        conversation.note("Spouštím chráněného Agenta…", in: turn)
        conversation.fail(turn, message: "Copilot CLI skončil.", at: end)

        #expect(conversation.turns[0].state == .failed("Copilot CLI skončil."))
        #expect(conversation.turns[0].activity.last?.kind == .notice)
        #expect(conversation.activeTurn == nil)
    }

    @Test("the instructions precede only the first question of an Agent session")
    func promptBlocks() {
        let first = BrainConversationInstructions.promptBlocks(question: "Who?", isFirstInSession: true)
        let followUp = BrainConversationInstructions.promptBlocks(question: "And?", isFirstInSession: false)

        #expect(first == [BrainConversationInstructions.text, "Who?"])
        #expect(followUp == ["And?"])
        #expect(BrainConversationInstructions.text.contains("_brain/"))
        #expect(BrainConversationInstructions.text.contains("Read-only"))
    }
}
