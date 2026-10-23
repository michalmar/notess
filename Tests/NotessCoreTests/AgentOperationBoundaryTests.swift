import Foundation
import Testing
@testable import NotessCore

/// Lets a test hold an operation's cleanup open until it chooses to finish it.
@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
        try #require(ContinuousClock.now < deadline, "timed out")
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
@Suite("Agent operation boundary")
struct AgentOperationBoundaryTests {
    let boundary = AgentOperationBoundary()
    let vault = Vault(rootURL: URL(filePath: "/tmp/notess-boundary-vault"))
    let otherVault = Vault(rootURL: URL(filePath: "/tmp/notess-boundary-other"))

    @Test("one operation owns the Vault at a time, whatever its kind")
    func exclusion() async throws {
        let gate = Gate()
        let brainRun = try #require(boundary.begin(.brainRun, in: vault) { _ in await gate.wait() })

        #expect(boundary.isOccupied)
        #expect(boundary.begin(.brainRun, in: vault) { _ in } == nil)
        #expect(boundary.begin(.conversationTurn, in: vault) { _ in } == nil)
        #expect(boundary.current === brainRun)

        gate.open()
        await boundary.waitUntilIdle()
        #expect(!boundary.isOccupied)
        #expect(boundary.current == nil)
        #expect(boundary.begin(.conversationTurn, in: vault) { _ in } != nil)
    }

    @Test("a conversation turn joins the boundary without a Brain Run")
    func conversationTurnOwns() async throws {
        let gate = Gate()
        let turn = try #require(boundary.begin(.conversationTurn, in: vault) { _ in await gate.wait() })

        #expect(turn.kind == .conversationTurn)
        #expect(turn.vault == vault)
        #expect(boundary.begin(.brainRun, in: vault) { _ in } == nil)
        gate.open()
        await boundary.waitUntilIdle()
    }

    @Test("cancelling keeps ownership until the operation has cleaned up")
    func cancellationKeepsOwnership() async throws {
        let cleanup = Gate()
        let started = Gate()
        let operation = try #require(boundary.begin(.brainRun, in: vault) { _ in
            await started.wait()
            // Stands in for terminating the owned process group.
            await cleanup.wait()
        })
        started.open()

        boundary.cancel(operation)
        boundary.cancel(operation)
        boundary.cancel(operation)
        await Task.yield()

        #expect(boundary.isOccupied)
        #expect(boundary.begin(.brainRun, in: vault) { _ in } == nil)

        cleanup.open()
        await boundary.waitUntilIdle()
        #expect(!boundary.isOccupied)
    }

    @Test("cancelling propagates to the operation's task")
    func cancellationReachesWork() async throws {
        let seen = Gate()
        let flag = Flag()
        let operation = try #require(boundary.begin(.brainRun, in: vault) { _ in
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            flag.value = true
            await seen.wait()
        })

        boundary.cancel(operation)
        try await waitUntil { flag.value }
        seen.open()
        await boundary.waitUntilIdle()
    }

    @Test("abandoning for a Vault change makes the operation stale but keeps the boundary occupied")
    func abandonKeepsOwnership() async throws {
        let cleanup = Gate()
        let operation = try #require(boundary.begin(.brainRun, in: vault) { _ in await cleanup.wait() })

        boundary.abandonCurrent()

        #expect(operation.isStale)
        #expect(boundary.current == nil)
        #expect(boundary.isOccupied)
        #expect(boundary.begin(.brainRun, in: otherVault) { _ in } == nil)

        cleanup.open()
        await boundary.waitUntilIdle()
        #expect(!boundary.isOccupied)
        #expect(operation.isStale)
        let next = boundary.begin(.brainRun, in: otherVault) { _ in }
        #expect(next != nil)
        #expect(next?.isStale == false)
        await boundary.waitUntilIdle()
    }

    @Test("repeated Vault changes cannot release a stale operation early")
    func repeatedAbandon() async throws {
        let cleanup = Gate()
        _ = try #require(boundary.begin(.brainRun, in: vault) { _ in await cleanup.wait() })

        boundary.abandonCurrent()
        boundary.abandonCurrent()

        #expect(boundary.isOccupied)
        cleanup.open()
        await boundary.waitUntilIdle()
        #expect(!boundary.isOccupied)
    }

    @Test("a finished operation is not stale, so its final report still counts")
    func finishedIsNotStale() async throws {
        let operation = try #require(boundary.begin(.brainRun, in: vault) { _ in })
        await boundary.waitUntilIdle()

        #expect(!operation.isStale)
        #expect(!boundary.isOccupied)
    }

    @Test("terminating cancels every owner, including stale ones, and waits for their cleanup")
    func terminate() async throws {
        let staleCleanup = Gate()
        let stale = try #require(boundary.begin(.brainRun, in: vault) { _ in await staleCleanup.wait() })
        boundary.abandonCurrent()
        #expect(stale.isStale)

        let finished = Flag()
        let waiting = Task { @MainActor in
            await boundary.terminate()
            finished.value = true
        }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(30))
        #expect(!finished.value)

        staleCleanup.open()
        await waiting.value
        #expect(finished.value)
        #expect(!boundary.isOccupied)
    }

    @Test("terminating an idle boundary returns at once")
    func terminateIdle() async {
        await boundary.terminate()
        #expect(!boundary.isOccupied)
    }
}

@MainActor
private final class Flag {
    var value = false
}
