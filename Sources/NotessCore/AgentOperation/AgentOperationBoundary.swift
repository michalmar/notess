import Foundation

public enum AgentOperationKind: Equatable, Sendable {
    /// Processes changed notes into Brain Notes; completion-oriented.
    case brainRun
    /// One question-and-answer turn of a Brain Conversation.
    case conversationTurn
}

/// Lets at most one Agent operation own the open Vault at a time, whatever its kind.
///
/// An operation starts with `begin(_:in:work:)` and owns the Vault until its `work`
/// returns. `work` must not return before everything the operation owns, such as
/// its Copilot CLI process group, is gone; so cancelling, changing the Vault or
/// quitting can never free the Vault while that cleanup is still running.
///
/// The boundary says nothing about *how* an operation talks to the Agent or what
/// it records: a Brain Run and a conversation turn each bring their own transport
/// and outcome. Operations only share ownership and cleanup.
///
/// An operation reports to the user only while `isStale` is false: a Vault change
/// makes the current operation stale, so its late output and completion are dropped
/// instead of reaching whatever operation or Vault comes next.
@MainActor
public final class AgentOperationBoundary {
    /// One owner of the boundary. Check `isStale` before applying any late event.
    @MainActor
    public final class Operation {
        public let kind: AgentOperationKind
        public let vault: Vault
        /// Cancellation was requested; ownership continues until the work has cleaned up.
        public fileprivate(set) var isCancelling = false
        /// The Vault was changed while the operation ran: nothing it reports counts any more.
        public fileprivate(set) var isStale = false
        fileprivate var task: Task<Void, Never>?

        fileprivate init(kind: AgentOperationKind, vault: Vault) {
            self.kind = kind
            self.vault = vault
        }
    }

    /// The operation that still reports to the user; `nil` once it was abandoned or finished.
    public private(set) var current: Operation?
    private var owners: [ObjectIdentifier: Operation] = [:]

    public init() {}

    /// Whether any operation, including a stale one still cleaning up, owns the Vault.
    public var isOccupied: Bool {
        !owners.isEmpty
    }

    /// Starts `work` as the owner, or returns `nil` when another operation owns the Vault.
    public func begin(
        _ kind: AgentOperationKind,
        in vault: Vault,
        work: @escaping @MainActor (Operation) async -> Void
    ) -> Operation? {
        guard owners.isEmpty else { return nil }
        let operation = Operation(kind: kind, vault: vault)
        let key = ObjectIdentifier(operation)
        owners[key] = operation
        current = operation
        // Runs after `begin` returns, so ownership is recorded before the work can finish.
        operation.task = Task { [weak self] in
            await work(operation)
            self?.release(key)
        }
        return operation
    }

    /// Asks the operation to stop. It keeps the Vault until its work returns; repeating this is harmless.
    public func cancel(_ operation: Operation) {
        guard owners[ObjectIdentifier(operation)] != nil else { return }
        operation.isCancelling = true
        operation.task?.cancel()
    }

    /// The Vault is being left: cancels the current operation and makes it stale.
    /// It keeps the Vault until its cleanup has finished.
    public func abandonCurrent() {
        guard let operation = current else { return }
        operation.isStale = true
        cancel(operation)
        current = nil
    }

    /// Cancels every owner and returns once all of them have cleaned up (on quit).
    public func terminate() async {
        for operation in owners.values {
            cancel(operation)
        }
        await waitUntilIdle()
    }

    /// Returns once no operation owns the Vault.
    public func waitUntilIdle() async {
        while let task = owners.values.first?.task {
            await task.value
        }
    }

    private func release(_ key: ObjectIdentifier) {
        guard let operation = owners.removeValue(forKey: key) else { return }
        if current === operation { current = nil }
    }
}
