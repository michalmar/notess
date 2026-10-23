import Foundation

/// One Brain Conversation: questions about the Vault and the Agent's answers, in order.
/// A pure value; the app applies Agent events to it and renders it.
public struct BrainConversation: Equatable, Sendable {
    public enum TurnState: Equatable, Sendable {
        /// The Agent is working; submission is unavailable.
        case running
        /// Stop was requested; the turn ends once the Agent or its process is gone.
        case stopping
        case completed
        /// The answer is partial. `reason` is `nil` when the user stopped the turn.
        case incomplete(reason: String?)
        /// No valid answer: the CLI, authentication, protocol or sandbox failed.
        case failed(String)

        public var isActive: Bool {
            self == .running || self == .stopping
        }
    }

    public struct Activity: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// A tool call (`kind` as ACP names it: read, search, execute, fetch, …).
            case tool(kind: String?, status: ACPToolCallStatus)
            /// A permission the Agent asked for and was allowed.
            case permission(option: String)
            /// Something Notess did, such as starting the protected Agent.
            case notice
        }

        public let id: String
        public var title: String
        public var kind: Kind
        public var details = ACPToolCallDetails()
    }

    public struct Turn: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let question: String
        public internal(set) var answer = ""
        public internal(set) var activity: [Activity] = []
        public internal(set) var state: TurnState = .running
        public let startedAt: Date
        public internal(set) var finishedAt: Date?
    }

    public let id: UUID
    public private(set) var turns: [Turn] = []

    public init(id: UUID = UUID()) {
        self.id = id
    }

    /// The turn still running or stopping; there is at most one.
    public var activeTurn: Turn? {
        turns.last.flatMap { $0.state.isActive ? $0 : nil }
    }

    /// Starts a turn; returns `nil` while another turn is active.
    public mutating func begin(question: String, at date: Date) -> UUID? {
        guard activeTurn == nil else { return nil }
        let turn = Turn(id: UUID(), question: question, startedAt: date)
        turns.append(turn)
        return turn.id
    }

    /// Applies an Agent event; ignored unless `turnID` is the active turn.
    public mutating func apply(_ event: ACPSessionEvent, to turnID: UUID) {
        guard let index = activeIndex(turnID) else { return }
        switch event {
        case .answerChunk(let text):
            turns[index].answer += text
        case .toolCall(let id, let title, let kind, let status):
            let activity = Activity(id: "tool:\(id)", title: title, kind: .tool(kind: kind, status: status))
            if let existing = turns[index].activity.firstIndex(where: { $0.id == activity.id }) {
                turns[index].activity[existing].title = title
                turns[index].activity[existing].kind = activity.kind
            } else {
                turns[index].activity.append(activity)
            }
        case .toolCallUpdate(let id, let title, let status):
            guard let existing = turns[index].activity.firstIndex(where: { $0.id == "tool:\(id)" }) else {
                turns[index].activity.append(Activity(
                    id: "tool:\(id)", title: title ?? id, kind: .tool(kind: nil, status: status ?? .inProgress)
                ))
                return
            }
            if let title, !title.isEmpty { turns[index].activity[existing].title = title }
            if let status, case .tool(let kind, _) = turns[index].activity[existing].kind {
                turns[index].activity[existing].kind = .tool(kind: kind, status: status)
            }
        case .toolDetails(let id, let details):
            if let existing = turns[index].activity.firstIndex(where: { $0.id == "tool:\(id)" }) {
                turns[index].activity[existing].details.merge(details)
                if let kind = details.kind, case .tool(_, let status) = turns[index].activity[existing].kind {
                    turns[index].activity[existing].kind = .tool(kind: kind, status: status)
                }
            } else {
                turns[index].activity.append(Activity(
                    id: "tool:\(id)", title: id, kind: .tool(kind: details.kind, status: .inProgress), details: details
                ))
            }
        case .permissionAllowed(let title, let option):
            turns[index].activity.append(Activity(
                id: "permission:\(turns[index].activity.count)", title: title, kind: .permission(option: option)
            ))
        }
    }

    /// Records something Notess did during the turn.
    public mutating func note(_ text: String, in turnID: UUID) {
        guard let index = activeIndex(turnID) else { return }
        turns[index].activity.append(Activity(
            id: "notice:\(turns[index].activity.count)", title: text, kind: .notice
        ))
    }

    public mutating func markStopping(_ turnID: UUID) {
        guard let index = activeIndex(turnID), turns[index].state == .running else { return }
        turns[index].state = .stopping
    }

    /// Ends the turn by how `session/prompt` ended. A stop the user asked for makes the
    /// answer incomplete even if the Agent reports a normal end.
    public mutating func finish(_ turnID: UUID, stopReason: ACPStopReason, at date: Date) {
        guard let index = activeIndex(turnID) else { return }
        let stopRequested = turns[index].state == .stopping
        switch stopReason {
        case _ where stopRequested, .cancelled:
            turns[index].state = .incomplete(reason: nil)
        case .endTurn:
            turns[index].state = .completed
        case .maxTokens:
            turns[index].state = .incomplete(reason: "Odpověď přesáhla limit délky.")
        case .maxTurnRequests:
            turns[index].state = .incomplete(reason: "Agent dosáhl limitu kroků Copilot CLI.")
        case .refusal:
            turns[index].state = .incomplete(reason: "Agent odpověď odmítl.")
        case .other(let raw):
            turns[index].state = .incomplete(reason: "Agent skončil neočekávaně (\(raw)).")
        }
        turns[index].finishedAt = date
    }

    /// Ends the turn as stopped by the user: what streamed so far stays, marked incomplete.
    public mutating func stop(_ turnID: UUID, at date: Date) {
        guard let index = activeIndex(turnID) else { return }
        turns[index].state = .incomplete(reason: nil)
        turns[index].finishedAt = date
    }

    public mutating func fail(_ turnID: UUID, message: String, at date: Date) {
        guard let index = activeIndex(turnID) else { return }
        turns[index].state = .failed(message)
        turns[index].finishedAt = date
    }

    private func activeIndex(_ turnID: UUID) -> Int? {
        guard let index = turns.indices.last, turns[index].id == turnID, turns[index].state.isActive else { return nil }
        return index
    }
}
