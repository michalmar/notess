import Foundation
import NotessCore
import Observation

enum BrainRunPhase: Equatable {
    case idle
    case running
    case cancelling
    case succeeded(processed: Int)
    case nothingToProcess
    case cancelled
    case failed(String)
}

/// Output of the current Brain Run. Kept apart from `AppModel` so streaming
/// output re-renders only the log, never the editor.
@MainActor
@Observable
final class BrainRunLog {
    private(set) var text = ""
    private static let limit = 256_000

    func reset(_ header: String = "") {
        text = header
    }

    func append(_ chunk: String) {
        text += chunk
        if text.utf8.count > Self.limit {
            text = "…\n" + String(text.suffix(Self.limit / 2))
        }
    }
}

extension AppModel {
    var isBrainRunActive: Bool {
        brainRunPhase == .running || brainRunPhase == .cancelling
    }

    /// Whether any Agent operation owns the Vault, including one cleaning up after a cancel or a Vault change.
    var isAgentOperationActive: Bool {
        agentOperations.isOccupied
    }

    /// "Zpracovat": lets the Agent process the notes changed since the last
    /// successful Brain Run, in the background.
    func startBrainRun() {
        guard let vault, !isBrainRunActive, !agentOperations.isOccupied else { return }
        brainRunPhase = .running
        brainRunLog.reset("Brain Run \(Date().formatted(date: .abbreviated, time: .standard))\n")
        let configuredPath = settings.copilotCLIPath
        let store = brainRunStateStore
        let runner = brainRunProcessRunner
        let log = brainRunLog
        brainRunOperation = agentOperations.begin(.brainRun, in: vault) { [weak self] operation in
            let resolution = await Task.detached {
                CopilotCLILocator().resolve(configuredPath: configuredPath)
            }.value
            guard let self, !operation.isStale else { return }
            guard case .found(let executable) = resolution else {
                self.finishBrainRun(operation, failure: Self.message(for: resolution), alert: true)
                return
            }
            if Task.isCancelled {
                self.finishBrainRun(operation, outcome: .cancelled)
                return
            }
            let run = BrainRun(vault: vault, executableURL: executable, store: store, runner: runner)
            self.brainRun = run
            log.append("Copilot CLI: \(executable.path(percentEncoded: false))\n")
            // Not isolated to the main actor: the run reads the Vault and waits for the CLI elsewhere.
            let outcome = await run.run(log: { chunk in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { if !operation.isStale { log.append(chunk) } }
                }
            })
            self.finishBrainRun(operation, outcome: outcome)
        }
    }

    /// "Zrušit": terminates Copilot CLI; the run does not count as successful.
    func cancelBrainRun() {
        guard brainRunPhase == .running, let operation = brainRunOperation else { return }
        brainRunPhase = .cancelling
        brainRunLog.append("\nRuším…\n")
        agentOperations.cancel(operation)
    }

    /// On quit: waits until every owned Copilot CLI process group is gone.
    func terminateAgentOperations() async {
        await agentOperations.terminate()
    }

    /// A new Vault starts with no run; a run of the previous Vault is cancelled and reports
    /// nothing, but keeps owning the Vault until its process group is gone.
    func resetBrainRun(for vault: Vault) {
        let wasBrainRunOwner = brainRunOperation != nil || brainRunPhase == .cancelling
        agentOperations.abandonCurrent()
        brainRunOperation = nil
        brainRun = nil
        agentCleanupWatcher?.cancel()
        let cleanupID = UUID()
        agentCleanupID = cleanupID
        if agentOperations.isOccupied, wasBrainRunOwner {
            brainRunPhase = .cancelling
            agentCleanupWatcher = Task { [weak self, agentOperations] in
                await agentOperations.waitUntilIdle()
                guard let self, self.agentCleanupID == cleanupID else { return }
                if self.brainRunPhase == .cancelling {
                    self.brainRunPhase = .idle
                }
            }
        } else {
            brainRunPhase = .idle
        }
        brainRunLog.reset()
        isBrainRunLogPresented = false
        lastSuccessfulBrainRun = nil
        let store = brainRunStateStore
        Task { [weak self] in
            let completedAt = await Task.detached {
                try? store.lastSuccessfulRun(for: vault)?.completedAt
            }.value
            guard let self, self.vault == vault, self.lastSuccessfulBrainRun == nil else { return }
            self.lastSuccessfulBrainRun = completedAt
        }
    }

    /// Tells the running Brain Run which files the user's last save wrote. If they
    /// cannot be read back, the run fails: stop the Agent.
    func acceptUserWriteDuringBrainRun(of document: NoteDocument) {
        guard let brainRun, let vault else { return }
        let paths = document.lastSaveWrittenFileURLs.compactMap { relativePath(for: $0, in: vault) }
        guard !paths.isEmpty else { return }
        do {
            try brainRun.acceptUserWrite(under: paths)
        } catch {
            stopBrainRun(unreadable: error)
        }
    }

    /// Outside changes during a run: if a file outside `_brain/` changed without
    /// the user saving it, stop the Agent at once; the run then fails with the list.
    func checkBrainRunBoundary(after change: VaultChange) {
        guard let brainRun, let operation = brainRunOperation, brainRunPhase == .running,
              change.requiresFullRescan
                || change.relativePaths.contains(where: { !VaultFileSnapshot.isInBrainFolder($0) })
        else { return }
        guard !isCheckingBrainRunBoundary else {
            needsBrainRunBoundaryRecheck = true
            return
        }
        isCheckingBrainRunBoundary = true
        needsBrainRunBoundaryRecheck = false
        Task { [weak self] in
            let checked = await Task.detached {
                Result { () throws(VaultSnapshotError) in try brainRun.changesOutsideBrain() }
            }.value
            guard let self else { return }
            self.isCheckingBrainRunBoundary = false
            guard !operation.isStale, self.brainRunPhase == .running else { return }
            switch checked {
            case .failure(let error):
                self.stopBrainRun(unreadable: error)
            case .success(let outside) where !outside.isEmpty:
                self.brainRunLog.append("\nZměna mimo _brain/: \(outside.joined(separator: ", ")). Zastavuji Agenta.\n")
                self.cancelBrainRun()
            case .success:
                if self.needsBrainRunBoundaryRecheck {
                    self.checkBrainRunBoundary(after: VaultChange(relativePaths: [], requiresFullRescan: true))
                }
            }
        }
    }

    /// A file outside `_brain/` could not be read during the run: the run already
    /// counts as failed, so stop the Agent; it then reports the failure.
    private func stopBrainRun(unreadable error: VaultSnapshotError) {
        guard brainRunPhase == .running else { return }
        brainRunLog.append("\n\(Self.unreadableDescription(error)). Zastavuji Agenta.\n")
        cancelBrainRun()
    }

    private func finishBrainRun(_ operation: AgentOperationBoundary.Operation, outcome: BrainRunOutcome) {
        guard !operation.isStale else { return }
        switch outcome {
        case .succeeded(let processed):
            lastSuccessfulBrainRun = Date()
            endBrainRun(.succeeded(processed: processed), logLine: "Hotovo: zpracováno poznámek: \(processed).")
        case .nothingToProcess:
            endBrainRun(.nothingToProcess, logLine: "Hotovo: od posledního zpracování se nic nezměnilo.")
        case .cancelled:
            endBrainRun(.cancelled, logLine: "Zrušeno. Běh se nepočítá jako úspěšný.")
        case .failed(let failure):
            let alert: Bool
            switch failure {
            case .changedOutsideBrain, .launch, .brainFolderUnavailable, .vaultUnreadable: alert = true
            default: alert = false
            }
            finishBrainRun(operation, failure: Self.message(for: failure), alert: alert)
        }
    }

    private func finishBrainRun(_ operation: AgentOperationBoundary.Operation, failure message: String, alert: Bool) {
        guard !operation.isStale else { return }
        endBrainRun(.failed(message), logLine: "Chyba: \(message)")
        if alert {
            errorMessage = message
        }
    }

    private func endBrainRun(_ phase: BrainRunPhase, logLine: String) {
        brainRun = nil
        brainRunOperation = nil
        isCheckingBrainRunBoundary = false
        needsBrainRunBoundaryRecheck = false
        brainRunPhase = phase
        let log = brainRunLog
        // After the output chunks still queued on the main queue.
        DispatchQueue.main.async { MainActor.assumeIsolated { log.append("\n\(logLine)\n") } }
        // New and removed Brain Notes show in the sidebar even if FSEvents is late.
        reconcileWithDisk()
    }

    private static func message(for resolution: CopilotCLIResolution) -> String {
        switch resolution {
        case .found:
            return ""
        case .configuredPathUnavailable(let path):
            return "Copilot CLI na cestě z Nastavení (\(path)) nebyl nalezen nebo není spustitelný. Opravte cestu v Nastavení (⌘,)."
        case .notFound:
            return "Copilot CLI nebyl nalezen. Nainstalujte GitHub Copilot CLI, nebo zadejte cestu k němu v Nastavení (⌘,)."
        }
    }

    private static func message(for failure: BrainRunFailure) -> String {
        switch failure {
        case .brainFolderUnavailable:
            return "Složka _brain je symbolický odkaz, Agent do ní nesmí zapisovat."
        case .preparation(let detail):
            return "Složku _brain se nepodařilo připravit: \(detail)"
        case .launch(let detail):
            return "Copilot CLI se nepodařilo spustit: \(detail)"
        case .exitStatus(let status):
            return "Copilot CLI skončil s chybou (kód \(status)). Podrobnosti jsou v logu."
        case .changedOutsideBrain(let paths):
            let shown = paths.prefix(10).joined(separator: ", ")
            let more = paths.count > 10 ? " a další (\(paths.count - 10))" : ""
            return "Během Brain Runu se mimo _brain/ změnily soubory, které jste neuložili vy: \(shown)\(more). Zkontrolujte je. Běh se nepočítá jako úspěšný."
        case .stateNotSaved(let detail):
            return "Brain Run doběhl, ale jeho stav se nepodařilo uložit, takže se poznámky zpracují znovu: \(detail)"
        case .vaultUnreadable(let error):
            return "\(unreadableDescription(error)). Zkontrolujte oprávnění a spusťte Zpracovat znovu. Běh se nepočítá jako úspěšný."
        }
    }

    private static func unreadableDescription(_ error: VaultSnapshotError) -> String {
        let item = error.relativePath.isEmpty ? "Vault" : "„\(error.relativePath)“"
        return "Nepodařilo se přečíst \(item): \(error.detail)"
    }
}
