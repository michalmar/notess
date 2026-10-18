import Foundation

/// Runs submitted work one pass at a time on the main actor.
///
/// Work submitted while a pass is running is merged into a single pending
/// pass, which starts as soon as the running one ends. A burst of submissions
/// therefore costs at most one running and one pending pass, and nothing
/// submitted is lost. Heavy work inside `perform` belongs off the main actor;
/// the pass awaits it and applies the results.
@MainActor
public final class CoalescingQueue<Work: Sendable> {
    private let merge: (inout Work, Work) -> Void
    private let perform: @MainActor (Work) async -> Void
    private var pending: Work?
    private var runningTask: Task<Void, Never>?
    private var isCancelled = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// How many passes have started; shows that bursts are coalesced.
    public private(set) var passCount = 0

    /// - Parameters:
    ///   - merge: Folds newly submitted work into the pending work.
    ///   - perform: One pass; it may submit follow-up work, which runs next.
    public init(
        merge: @escaping (inout Work, Work) -> Void,
        perform: @escaping @MainActor (Work) async -> Void
    ) {
        self.merge = merge
        self.perform = perform
    }

    /// No pass is running and none is waiting.
    public var isIdle: Bool {
        runningTask == nil && pending == nil
    }

    public func submit(_ work: Work) {
        guard !isCancelled else { return }
        if var merged = pending {
            merge(&merged, work)
            pending = merged
        } else {
            pending = work
        }
        startNextPass()
    }

    /// Drops pending work and cancels the running pass; later submissions are ignored.
    public func cancel() {
        isCancelled = true
        pending = nil
        runningTask?.cancel()
    }

    /// Returns once no pass is running or waiting.
    public func waitUntilIdle() async {
        guard !isIdle else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func startNextPass() {
        guard runningTask == nil else { return }
        guard !isCancelled, let work = pending else {
            resumeIdleWaiters()
            return
        }
        pending = nil
        passCount += 1
        runningTask = Task {
            await perform(work)
            runningTask = nil
            startNextPass()
        }
    }

    private func resumeIdleWaiters() {
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }
}
