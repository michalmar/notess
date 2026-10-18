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
    /// A file or folder outside `_brain/` exists but could not be listed or read, so the
    /// notes to process or the changes during the run are unknown. Before the start this
    /// keeps Copilot CLI from starting; during the run it fails the run.
    case vaultUnreadable(VaultSnapshotError)
}

/// One Brain Run: picks the notes changed since the last successful run, lets
/// Copilot CLI (the Agent) process them into `_brain/`, and remembers the run
/// only when it succeeded.
///
/// While it runs, it watches the files outside `_brain/`: any change there that
/// the user did not save (`acceptUserWrite(under:)`) fails the run, and so does
/// any file there that cannot be read, since its state is then unknown.
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
    /// The first file outside `_brain/` that could not be read during the run: the run fails.
    private var unreadable: VaultSnapshotError?

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
            unreadable = nil
        }
        defer {
            lock.withLock {
                isRunning = false
                expected = nil
                scopesAcceptedBeforeSnapshot = []
                unreadable = nil
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

        let baseline: VaultFileSnapshot
        do {
            baseline = try VaultFileSnapshot.capture(of: vault)
        } catch {
            log("\(error). Copilot CLI was not started.\n")
            return .failed(.vaultUnreadable(error))
        }
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
        let started = lock.withLock {
            let result = Result { () throws(VaultSnapshotError) in
                try overlay(baseline, with: scopesAcceptedBeforeSnapshot)
            }
            expected = try? result.get()
            scopesAcceptedBeforeSnapshot = []
            return result
        }
        if case .failure(let error) = started {
            log("\(error). Copilot CLI was not started.\n")
            return .failed(.vaultUnreadable(error))
        }

        var launchError: String?
        var status: Int32 = 0
        do {
            status = try await runner.run(command, output: log)
        } catch is CancellationError {
        } catch {
            launchError = error.localizedDescription
        }

        let completed = launchError == nil && status == 0 && !Task.isCancelled
            && lock.withLock({ unreadable }) == nil
        // A cancelled or failed Agent may be mid-edit: leave its notes as they are.
        if completed { deleteEmptyBrainNotes(log: log) }
        let outside: [String]
        do {
            outside = try changesOutsideBrain()
        } catch {
            // Recorded as `unreadable` below.
            outside = []
        }
        // What was expected is unreliable once a file could not be read, so that comes first.
        if let unreadable = lock.withLock({ unreadable }) {
            log("\(unreadable). The run does not count as successful.\n")
            return .failed(.vaultUnreadable(unreadable))
        }
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
    /// paths (see `NoteDocument.lastSaveWrittenFileURLs`), so the change is not reported.
    /// Call it right after the save; does nothing when no Agent is running.
    ///
    /// Throws when a saved file cannot be read back. The expectation then stays as it
    /// was and the run fails: stop the Agent.
    public func acceptUserWrite(under relativePaths: [String]) throws(VaultSnapshotError) {
        let accepted: Result<Void, VaultSnapshotError> = lock.withLock {
            guard isRunning else { return .success(()) }
            guard let expected else {
                scopesAcceptedBeforeSnapshot += relativePaths
                return .success(())
            }
            do throws(VaultSnapshotError) {
                self.expected = try overlay(expected, with: relativePaths)
                return .success(())
            } catch {
                if unreadable == nil { unreadable = error }
                return .failure(error)
            }
        }
        try accepted.get()
    }

    /// `snapshot` with the files at or below `scopes` as they are now; throws,
    /// changing nothing, when any of them cannot be read.
    private func overlay(_ snapshot: VaultFileSnapshot, with scopes: [String]) throws(VaultSnapshotError) -> VaultFileSnapshot {
        var snapshot = snapshot
        for scope in scopes where !VaultFileSnapshot.isInBrainFolder(scope) {
            let current = try VaultFileSnapshot.capture(of: vault, under: scope)
            snapshot.fingerprints = snapshot.fingerprints.filter {
                $0.key != scope && !$0.key.hasPrefix(scope + "/")
            }
            snapshot.fingerprints.merge(current.fingerprints) { _, new in new }
        }
        return snapshot
    }

    /// Vault-relative paths outside `_brain/` that changed since the run started
    /// without the user saving them, sorted. Empty when no Agent is running.
    /// Reads the whole Vault: call it off the main thread.
    ///
    /// Throws when a file or folder outside `_brain/` cannot be read: whether it
    /// changed is unknown, and the run fails, so stop the Agent.
    public func changesOutsideBrain() throws(VaultSnapshotError) -> [String] {
        guard let expected = lock.withLock({ expected }) else { return [] }
        do {
            let current = try VaultFileSnapshot.capture(of: vault).fingerprints
            let suspects = Set(expected.fingerprints.keys).union(current.keys)
                .filter { expected.fingerprints[$0] != current[$0] }
            guard !suspects.isEmpty else { return [] }
            // The user may have saved while the Vault was being read: look at the
            // suspects again, against the latest expectation.
            let latest = lock.withLock { self.expected } ?? expected
            var changed: [String] = []
            for suspect in suspects.sorted()
            where try latest.fingerprints[suspect]
                != VaultFileSnapshot.capture(of: vault, under: suspect).fingerprints[suspect] {
                changed.append(suspect)
            }
            return changed
        } catch {
            lock.withLock {
                if isRunning, self.expected != nil, unreadable == nil { unreadable = error }
            }
            throw error
        }
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
