import Foundation
@testable import Notess
@testable import NotessCore

/// Stands in for Copilot CLI's ACP connection; the test scripts each prompt.
final class FakeConnection: ACPConnection, @unchecked Sendable {
    enum Command {
        case event(ACPSessionEvent)
        case finish(ACPStopReason)
        case fail(BrainConversationError)
    }

    let vault: Vault
    private let lock = NSLock()
    private var startError: BrainConversationError?
    private var honoursCancel = true
    private var open = false
    private var started = 0
    private var closed = 0
    private var cancelled = 0
    private var blocks: [[String]] = []
    private var commands: AsyncStream<Command>.Continuation?
    private var lastEvents: (@Sendable (ACPSessionEvent) -> Void)?
    private var holdsClose = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    init(vault: Vault, startError: BrainConversationError? = nil, honoursCancel: Bool = true, holdsClose: Bool = false) {
        self.vault = vault
        self.startError = startError
        self.honoursCancel = honoursCancel
        self.holdsClose = holdsClose
    }

    var startCount: Int { lock.withLock { started } }
    var closeCount: Int { lock.withLock { closed } }
    var cancelCount: Int { lock.withLock { cancelled } }
    var prompts: [[String]] { lock.withLock { blocks } }
    var isPrompting: Bool { lock.withLock { commands != nil } }

    func send(_ command: Command) {
        lock.withLock { commands }?.yield(command)
    }

    /// Delivers an event through the last prompt's handler, even after that prompt ended.
    func sendLate(_ event: ACPSessionEvent) {
        lock.withLock { lastEvents }?(event)
    }

    func releaseClose() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            holdsClose = false
            defer { closeWaiters = [] }
            return closeWaiters
        }
        waiters.forEach { $0.resume() }
    }

    func start() async throws(BrainConversationError) {
        let error: BrainConversationError? = lock.withLock {
            started += 1
            if startError == nil { open = true }
            return startError
        }
        if let error { throw error }
    }

    func prompt(
        _ blocks: [String],
        events: @escaping @Sendable (ACPSessionEvent) -> Void
    ) async throws(BrainConversationError) -> ACPStopReason {
        let (stream, continuation) = AsyncStream.makeStream(of: Command.self)
        lock.withLock {
            self.blocks.append(blocks)
            commands = continuation
            lastEvents = events
        }
        let result: Result<ACPStopReason, BrainConversationError> = await withTaskCancellationHandler {
            for await command in stream {
                switch command {
                case .event(let event):
                    events(event)
                case .finish(let reason):
                    return .success(reason)
                case .fail(let error):
                    lock.withLock { open = false }
                    return .failure(error)
                }
            }
            return .success(.cancelled)
        } onCancel: {
            let honours = lock.withLock {
                cancelled += 1
                if !honoursCancel { open = false }
                return honoursCancel
            }
            if honours {
                continuation.yield(.finish(.cancelled))
            } else {
                continuation.finish()
            }
        }
        lock.withLock { commands = nil }
        return try result.get()
    }

    func isOpen() async -> Bool {
        lock.withLock { open }
    }

    func close() async {
        let hold = lock.withLock {
            closed += 1
            open = false
            return holdsClose
        }
        guard hold else { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if !holdsClose { return true }
                closeWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

/// Makes the connections AppModel asks for and keeps them for the test.
@MainActor
final class Connections {
    var made: [FakeConnection] = []
    var startError: BrainConversationError?
    var honoursCancel = true
    var holdsClose = false

    var factory: BrainConversationConnectionFactory {
        { [unowned self] vault, _ in
            let connection = FakeConnection(
                vault: vault, startError: startError, honoursCancel: honoursCancel, holdsClose: holdsClose
            )
            made.append(connection)
            return connection
        }
    }

    var last: FakeConnection { made[made.count - 1] }
}
