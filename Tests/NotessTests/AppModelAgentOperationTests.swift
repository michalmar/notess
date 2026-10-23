import Foundation
import Testing
@testable import Notess
@testable import NotessCore

/// Stands in for Copilot CLI. `hold` runs until cancelled, then keeps "cleaning up"
/// (the process group still exists) until the test lets it finish.
private final class ControlledRunner: BrainRunProcessRunner, @unchecked Sendable {
    enum Mode { case succeed, hold }

    private let lock = NSLock()
    private var mode: Mode
    private var launched = 0
    private var cleanupOpen = false
    private var cleanupContinuation: CheckedContinuation<Void, Never>?
    private var emitAfterCancel: String?

    init(_ mode: Mode, emitAfterCancel: String? = nil) {
        self.mode = mode
        self.emitAfterCancel = emitAfterCancel
    }

    var launchCount: Int { lock.withLock { launched } }

    func finishCleanup() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            cleanupOpen = true
            defer { cleanupContinuation = nil }
            return cleanupContinuation
        }
        continuation?.resume()
    }

    func run(_ command: BrainRunCommand, output: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        let mode = lock.withLock { launched += 1; return self.mode }
        output("started\n")
        guard mode == .hold else { return 0 }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
        }
        if let emitAfterCancel { output(emitAfterCancel) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock {
                if cleanupOpen { return true }
                cleanupContinuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
        throw CancellationError()
    }
}

@MainActor
private func waitForOperation(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(20)
    while !condition() {
        try #require(ContinuousClock.now < deadline, "timed out")
        try await Task.sleep(for: .milliseconds(5))
    }
}

private final class Fixture {
    let rootURL: URL
    let otherURL: URL
    let storeURL: URL
    private let defaultsSuiteName = "NotessAgentOperationTests-\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "NotessAgentOperationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        rootURL = base.appending(path: "vault", directoryHint: .isDirectory)
        otherURL = base.appending(path: "other", directoryHint: .isDirectory)
        storeURL = base.appending(path: "state", directoryHint: .isDirectory)
        for url in [rootURL, otherURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try "# Plan\n".write(
                to: url.appending(path: "Plan.md", directoryHint: .notDirectory), atomically: true, encoding: .utf8
            )
        }
        defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: rootURL.deletingLastPathComponent())
    }

    var store: BrainRunStateStore { BrainRunStateStore(directoryURL: storeURL) }

    @MainActor
    func makeModel(runner: any BrainRunProcessRunner) -> AppModel {
        VaultLocationStore(defaults: defaults).remember(Vault(rootURL: rootURL))
        let settings = AppSettings(defaults: defaults)
        // Any executable satisfies the locator; the runner never starts it.
        settings.copilotCLIPath = "/bin/sh"
        return AppModel(
            vaultLocationStore: VaultLocationStore(defaults: defaults),
            tabRestorationStore: TabRestorationStore(defaults: defaults),
            settings: settings,
            brainRunStateStore: store,
            brainRunProcessRunner: runner,
            tagGroupStore: TagGroupStore(directoryURL: storeURL.appending(path: "tags", directoryHint: .isDirectory)),
            now: { Date(timeIntervalSince1970: 1_760_765_000) }
        )
    }
}

@MainActor
@Suite("Agent operation ownership")
struct AppModelAgentOperationTests {
    @Test("a successful Brain Run still records the last-successful baseline")
    func successRecordsBaseline() async throws {
        let fixture = try Fixture()
        let runner = ControlledRunner(.succeed)
        let model = fixture.makeModel(runner: runner)

        model.startBrainRun()
        try await waitForOperation { model.brainRunPhase.processed != nil }

        #expect(model.brainRunPhase.processed ?? 0 >= 1)
        #expect(model.lastSuccessfulBrainRun != nil)
        #expect(try fixture.store.lastSuccessfulRun(for: Vault(rootURL: fixture.rootURL)) != nil)
        #expect(!model.isAgentOperationActive)
    }

    @Test("a second start is refused while the Brain Run owns the Vault")
    func startIsExclusive() async throws {
        let fixture = try Fixture()
        let runner = ControlledRunner(.hold)
        let model = fixture.makeModel(runner: runner)

        model.startBrainRun()
        try await waitForOperation { runner.launchCount == 1 }
        model.startBrainRun()
        model.startBrainRun()
        try await Task.sleep(for: .milliseconds(50))

        #expect(runner.launchCount == 1)
        #expect(model.agentOperations.current?.kind == .brainRun)

        runner.finishCleanup()
        model.cancelBrainRun()
        try await waitForOperation { !model.isAgentOperationActive }
    }

    @Test("cancelling keeps ownership until the process cleanup is done, however often it is repeated")
    func cancelKeepsOwnershipUntilCleanup() async throws {
        let fixture = try Fixture()
        let runner = ControlledRunner(.hold)
        let model = fixture.makeModel(runner: runner)

        model.startBrainRun()
        try await waitForOperation { runner.launchCount == 1 }
        model.cancelBrainRun()
        model.cancelBrainRun()
        model.cancelBrainRun()
        try await Task.sleep(for: .milliseconds(50))

        #expect(model.brainRunPhase == .cancelling)
        #expect(model.isAgentOperationActive)
        model.startBrainRun()
        try await Task.sleep(for: .milliseconds(30))
        #expect(runner.launchCount == 1)
        #expect(model.brainRunPhase == .cancelling)

        runner.finishCleanup()
        try await waitForOperation { model.brainRunPhase == .cancelled }

        #expect(!model.isAgentOperationActive)
        #expect(model.lastSuccessfulBrainRun == nil)
        #expect(try fixture.store.lastSuccessfulRun(for: Vault(rootURL: fixture.rootURL)) == nil)
    }

    @Test("a Vault change keeps the old run's ownership until cleanup, then the stale run reports nothing")
    func vaultChange() async throws {
        let fixture = try Fixture()
        let runner = ControlledRunner(.hold, emitAfterCancel: "late output\n")
        let model = fixture.makeModel(runner: runner)

        model.startBrainRun()
        try await waitForOperation { runner.launchCount == 1 }
        model.chooseVault(at: fixture.otherURL)
        model.chooseVault(at: fixture.otherURL)
        try await Task.sleep(for: .milliseconds(50))

        #expect(model.brainRunPhase == .cancelling)
        #expect(model.isAgentOperationActive)
        model.startBrainRun()
        try await Task.sleep(for: .milliseconds(30))
        #expect(runner.launchCount == 1)

        runner.finishCleanup()
        try await waitForOperation { !model.isAgentOperationActive }
        try await waitForOperation { model.brainRunPhase == .idle }
        // Output queued on the main queue by the stale run.
        try await Task.sleep(for: .milliseconds(50))

        #expect(model.brainRunLog.text.isEmpty)
        #expect(model.errorMessage == nil)
        #expect(model.lastSuccessfulBrainRun == nil)
        #expect(try fixture.store.lastSuccessfulRun(for: Vault(rootURL: fixture.otherURL)) == nil)
    }

    @Test("after the old run has cleaned up, the new Vault can start its own run")
    func newVaultRunsAfterCleanup() async throws {
        let fixture = try Fixture()
        let runner = ControlledRunner(.hold)
        let model = fixture.makeModel(runner: runner)

        model.startBrainRun()
        try await waitForOperation { runner.launchCount == 1 }
        model.chooseVault(at: fixture.otherURL)
        runner.finishCleanup()
        try await waitForOperation { model.brainRunPhase == .idle && !model.isAgentOperationActive }

        model.startBrainRun()
        try await waitForOperation { runner.launchCount == 2 }
        #expect(model.brainRunPhase == .running)
        #expect(model.agentOperations.current?.vault == Vault(rootURL: fixture.otherURL))

        model.cancelBrainRun()
        try await waitForOperation { model.brainRunPhase == .cancelled }
    }

    @Test("quitting waits for the owned process cleanup")
    func quitWaitsForCleanup() async throws {
        let fixture = try Fixture()
        let runner = ControlledRunner(.hold)
        let model = fixture.makeModel(runner: runner)

        model.startBrainRun()
        try await waitForOperation { runner.launchCount == 1 }
        let finished = QuitFlag()
        let quitting = Task { @MainActor in
            await model.terminateAgentOperations()
            finished.value = true
        }
        try await Task.sleep(for: .milliseconds(80))
        #expect(!finished.value)
        #expect(model.isAgentOperationActive)

        runner.finishCleanup()
        await quitting.value
        #expect(finished.value)
        #expect(!model.isAgentOperationActive)
        #expect(try fixture.store.lastSuccessfulRun(for: Vault(rootURL: fixture.rootURL)) == nil)
    }
}

@MainActor
private final class QuitFlag {
    var value = false
}

private extension BrainRunPhase {
    var processed: Int? {
        if case .succeeded(let processed) = self { return processed }
        return nil
    }
}
