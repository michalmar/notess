import Foundation

/// Runs a process to completion, streaming its output (stdout and stderr together).
/// Cancelling the calling task must stop the process.
public protocol BrainRunProcessRunner: Sendable {
    /// Returns the exit status; throws when the process cannot be started.
    func run(_ command: BrainRunCommand, output: @escaping @Sendable (String) -> Void) async throws -> Int32
}

public enum BrainRunOutcome: Equatable, Sendable {
    /// The Agent finished; `processed` changed and deleted notes are now remembered as processed.
    case succeeded(processed: Int)
    /// No note changed since the last successful Brain Run; Copilot CLI was not started.
    case nothingToProcess
    /// The user cancelled; nothing is remembered.
    case cancelled
    case failed(BrainRunFailure)
}

public enum BrainRunFailure: Equatable, Sendable, Error {
    /// `_brain` is a symlink, so the Agent is not let near it.
    case brainFolderUnavailable
    /// `_brain/` or its instructions could not be prepared.
    case preparation(String)
    /// Copilot CLI could not be started.
    case launch(String)
    case exitStatus(Int32)
    /// Vault-relative paths outside `_brain/` that changed during the run without the user saving them.
    case changedOutsideBrain([String])
    /// The run worked but could not be remembered.
    case stateNotSaved(String)
}

/// One Brain Run: picks the notes changed since the last successful run, lets
/// Copilot CLI (the Agent) process them into `_brain/`, and remembers the run
/// only when it succeeded.
///
/// While it runs, it watches the files outside `_brain/`: any change there that
/// the user did not save (`acceptUserWrite(under:)`) fails the run.
public final class BrainRun: @unchecked Sendable {
    private let vault: Vault
    private let executableURL: URL
    private let store: BrainRunStateStore
    private let runner: any BrainRunProcessRunner
    private let now: @Sendable () -> Date

    private let lock = NSLock()
    private var isRunning = false
    /// What the files outside `_brain/` should look like now: the snapshot from the
    /// start of the run plus the user's saves since. `nil` until that snapshot exists.
    private var expected: VaultFileSnapshot?
    /// The user's saves while the start snapshot was being taken.
    private var scopesAcceptedBeforeSnapshot: [String] = []

    public init(
        vault: Vault,
        executableURL: URL,
        store: BrainRunStateStore = BrainRunStateStore(),
        runner: any BrainRunProcessRunner = SystemProcessRunner(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.vault = vault
        self.executableURL = executableURL
        self.store = store
        self.runner = runner
        self.now = now
    }

    /// Runs once. Cancel the calling task to cancel the run.
    public func run(log: @escaping @Sendable (String) -> Void) async -> BrainRunOutcome {
        lock.withLock {
            isRunning = true
            scopesAcceptedBeforeSnapshot = []
        }
        defer {
            lock.withLock {
                isRunning = false
                expected = nil
                scopesAcceptedBeforeSnapshot = []
            }
        }
        guard vault.isBrainFolderAvailable else { return .failed(.brainFolderUnavailable) }
        let instructions: String
        do {
            try vault.ensureBrainInstructions()
            try createEntityFolders()
            instructions = try String(contentsOf: vault.brainInstructionsURL, encoding: .utf8)
        } catch {
            return .failed(.preparation(error.localizedDescription))
        }

        let baseline = VaultFileSnapshot.capture(of: vault)
        let previous: BrainRunRecord?
        do {
            previous = try store.lastSuccessfulRun(for: vault)
        } catch {
            log("Previous Brain Run state is unreadable; processing every note. (\(error.localizedDescription))\n")
            previous = nil
        }
        let changes = BrainRunChanges(since: previous?.snapshot, current: baseline)
        guard !changes.isEmpty else {
            log("Nothing changed since the last successful Brain Run.\n")
            return .nothingToProcess
        }
        log(Self.summary(of: changes))
        if Task.isCancelled { return .cancelled }

        let command = BrainRunCommand.copilot(
            executableURL: executableURL,
            vault: vault,
            prompt: BrainRunPrompt.make(instructions: instructions, changes: changes)
        )
        lock.withLock {
            expected = overlay(baseline, with: scopesAcceptedBeforeSnapshot)
            scopesAcceptedBeforeSnapshot = []
        }

        var launchError: String?
        var status: Int32 = 0
        do {
            status = try await runner.run(command, output: log)
        } catch is CancellationError {
        } catch {
            launchError = error.localizedDescription
        }

        deleteEmptyBrainNotes(log: log)
        let outside = changesOutsideBrain()
        if !outside.isEmpty { return .failed(.changedOutsideBrain(outside)) }
        if Task.isCancelled { return .cancelled }
        if let launchError { return .failed(.launch(launchError)) }
        guard status == 0 else { return .failed(.exitStatus(status)) }

        do {
            // The start snapshot: notes the user saved during the run go to the next one.
            try store.rememberSuccessfulRun(BrainRunRecord(completedAt: now(), snapshot: baseline), for: vault)
        } catch {
            return .failed(.stateNotSaved(error.localizedDescription))
        }
        return .succeeded(processed: changes.changed.count + changes.deleted.count)
    }

    /// Records that the user just saved the files at or below these Vault-relative
    /// paths (a note, its `attachments/` folder), so the change is not reported.
    /// Call it right after the save; does nothing when no Agent is running.
    public func acceptUserWrite(under relativePaths: [String]) {
        lock.withLock {
            guard isRunning else { return }
            if let expected {
                self.expected = overlay(expected, with: relativePaths)
            } else {
                scopesAcceptedBeforeSnapshot += relativePaths
            }
        }
    }

    /// `snapshot` with the files at or below `scopes` as they are now.
    private func overlay(_ snapshot: VaultFileSnapshot, with scopes: [String]) -> VaultFileSnapshot {
        var snapshot = snapshot
        for scope in scopes where !VaultFileSnapshot.isInBrainFolder(scope) {
            snapshot.fingerprints = snapshot.fingerprints.filter {
                $0.key != scope && !$0.key.hasPrefix(scope + "/")
            }
            snapshot.fingerprints.merge(
                VaultFileSnapshot.capture(of: vault, under: scope).fingerprints
            ) { _, new in new }
        }
        return snapshot
    }

    /// Vault-relative paths outside `_brain/` that changed since the run started
    /// without the user saving them, sorted. Empty when no Agent is running.
    /// Reads the whole Vault: call it off the main thread.
    public func changesOutsideBrain() -> [String] {
        guard let expected = lock.withLock({ expected }) else { return [] }
        let current = VaultFileSnapshot.capture(of: vault).fingerprints
        let suspects = Set(expected.fingerprints.keys).union(current.keys)
            .filter { expected.fingerprints[$0] != current[$0] }
        guard !suspects.isEmpty else { return [] }
        // The user may have saved while the Vault was being read: look at the
        // suspects again, against the latest expectation.
        let latest = lock.withLock { self.expected } ?? expected
        return suspects.filter {
            latest.fingerprints[$0] != VaultFileSnapshot.capture(of: vault, under: $0).fingerprints[$0]
        }.sorted()
    }

    private func createEntityFolders() throws {
        for type in vault.entityTypes() {
            let url = vault.rootURL.appending(
                path: "\(NoteKind.brainFolder)/\(type.folder)", directoryHint: .isDirectory
            )
            guard vault.contains(url) else { continue }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// The Agent cannot delete files, so it empties Brain Notes that lost all their facts.
    private func deleteEmptyBrainNotes(log: (String) -> Void) {
        guard vault.isBrainFolderAvailable else { return }
        let brain = vault.rootURL.appending(path: NoteKind.brainFolder, directoryHint: .isDirectory)
        let rootPath = vault.rootURL.resolvingSymlinksInPath().path + "/"
        guard let enumerator = FileManager.default.enumerator(
            at: brain,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let path = url.resolvingSymlinksInPath().path
            guard values?.isRegularFile == true, values?.isSymbolicLink != true,
                  path.hasPrefix(rootPath) else { continue }
            let relative = String(path.dropFirst(rootPath.count))
            guard NoteKind.classify(relativePath: relative) == .brainNote,
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                log("Deleted empty Brain Note \(relative)\n")
            } catch {
                log("Could not delete empty Brain Note \(relative): \(error.localizedDescription)\n")
            }
        }
    }

    private static func summary(of changes: BrainRunChanges) -> String {
        var lines = ["Brain Run: \(changes.changed.count) changed or new, \(changes.deleted.count) deleted notes."]
        lines += changes.changed.map { "  + \($0)" }
        lines += changes.deleted.map { "  - \($0)" }
        return lines.joined(separator: "\n") + "\n\n"
    }
}
