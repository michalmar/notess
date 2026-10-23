import Foundation

/// Status of one Agent tool call, as ACP reports it.
public enum ACPToolCallStatus: String, Equatable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
    case failed
}

/// Optional evidence supplied by ACP, kept verbatim rather than inferred from titles.
/// Nil means the update did not supply that field; sparse updates preserve earlier data.
public struct ACPToolCallDetails: Equatable, Sendable {
    public var input: JSONValue?
    public var output: JSONValue?
    public var content: [JSONValue]?
    public var locations: [JSONValue]?
    public var kind: String?

    public init(
        input: JSONValue? = nil, output: JSONValue? = nil,
        content: [JSONValue]? = nil, locations: [JSONValue]? = nil, kind: String? = nil
    ) {
        self.input = input
        self.output = output
        self.content = content
        self.locations = locations
        self.kind = kind
    }

    mutating func merge(_ update: Self) {
        if let input = update.input { self.input = input }
        if let output = update.output { self.output = output }
        if let content = update.content { self.content = content }
        if let locations = update.locations { self.locations = locations }
        if let kind = update.kind { self.kind = kind }
    }
}

/// What the Agent reports while it works on one prompt.
public enum ACPSessionEvent: Equatable, Sendable {
    /// Visible answer text; reasoning ("thought") chunks are not reported.
    case answerChunk(String)
    case toolCall(id: String, title: String, kind: String?, status: ACPToolCallStatus)
    case toolCallUpdate(id: String, title: String?, status: ACPToolCallStatus?)
    case toolDetails(id: String, details: ACPToolCallDetails)
    /// The Agent asked for a permission and the connection allowed it, choosing `option`.
    case permissionAllowed(title: String, option: String)
}

/// Why `session/prompt` ended. Only `endTurn` is a complete answer.
public enum ACPStopReason: Equatable, Sendable {
    case endTurn
    case cancelled
    case maxTokens
    case maxTurnRequests
    case refusal
    case other(String)

    init(_ raw: String) {
        switch raw {
        case "end_turn": self = .endTurn
        case "cancelled": self = .cancelled
        case "max_tokens": self = .maxTokens
        case "max_turn_requests": self = .maxTurnRequests
        case "refusal": self = .refusal
        default: self = .other(raw)
        }
    }
}

/// Why a Brain Conversation turn could not run or finish. Each one is reported as an
/// error, never as an answer.
public enum BrainConversationError: Error, Equatable, Sendable {
    /// The Vault write sandbox is unavailable or ineffective; nothing was started.
    case sandbox(VaultWriteSandboxError)
    case launch(String)
    /// The saved Agent session could not be loaded (it no longer exists, or the Agent
    /// cannot load sessions). The conversation never silently continues without it.
    case sessionUnavailable(String)
    case authentication(String)
    /// The Agent broke the ACP protocol or did not answer in time.
    case protocolViolation(String)
    /// The Agent answered a request with an error.
    case agent(String)
    /// The Copilot CLI process ended before the turn finished.
    case exited(status: Int32, detail: String)
}

/// The one boundary between Brain Conversation behaviour and the Agent transport.
/// The app talks only to this; `CopilotACPConnection` implements it with Copilot CLI
/// in ACP mode, tests substitute it.
///
/// One connection holds one live Agent session, so follow-up prompts keep context.
public protocol ACPConnection: AnyObject, Sendable {
    /// The ACP session this connection holds; `nil` before `start` and after it ended.
    var sessionID: String? { get }

    /// Verifies the Vault write protection, then launches the Agent and opens a session:
    /// a new one, or `sessionID` through `session/load` to continue a saved conversation.
    /// Either way the sandbox and launch checks run first; nothing is launched unprotected.
    /// What `session/load` replays is the Agent's own record of earlier turns and is never
    /// reported as events: the persisted transcript stays authoritative, so nothing is
    /// duplicated and no earlier prompt is resubmitted.
    func start(resuming sessionID: String?) async throws(BrainConversationError)

    /// Sends one prompt and reports its events until `session/prompt` answers; a final
    /// streamed chunk alone does not end the turn. Cancelling the calling task sends
    /// `session/cancel` and, if the Agent does not stop soon, terminates the owned
    /// process group; the prompt then returns `.cancelled` once the group is gone.
    func prompt(
        _ blocks: [String],
        events: @escaping @Sendable (ACPSessionEvent) -> Void
    ) async throws(BrainConversationError) -> ACPStopReason

    /// Whether the session can take a follow-up prompt.
    func isOpen() async -> Bool

    /// Terminates the owned process group and returns once it is gone. Repeating it is harmless.
    func close() async
}

extension ACPConnection {
    /// Starts a new session.
    public func start() async throws(BrainConversationError) {
        try await start(resuming: nil)
    }
}
