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

    /// "Zpracovat": lets the Agent process the notes changed since the last
    /// successful Brain Run, in the background.
    func startBrainRun() {
        guard let vault, !isBrainRunActive else { return }
        let id = UUID()
        brainRunID = id
        brainRunPhase = .running
        brainRunLog.reset("Brain Run \(Date().formatted(date: .abbreviated, time: .standard))\n")
        let configuredPath = settings.copilotCLIPath
        let store = brainRunStateStore
        let log = brainRunLog
        brainRunTask = Task { [weak self] in
            let resolution = await Task.detached {
                CopilotCLILocator().resolve(configuredPath: configuredPath)
            }.value
            guard let self, self.brainRunID == id else { return }
            guard case .found(let executable) = resolution else {
                self.finishBrainRun(id: id, failure: Self.message(for: resolution), alert: true)
                return
            }
            if Task.isCancelled {
                self.finishBrainRun(id: id, outcome: .cancelled)
                return
            }
            let run = BrainRun(vault: vault, executableURL: executable, store: store)
            self.brainRun = run
            log.append("Copilot CLI: \(executable.path(percentEncoded: false))\n")
            // Not isolated to the main actor: the run reads the Vault and waits for the CLI elsewhere.
            let outcome = await run.run(log: { chunk in
                DispatchQueue.main.async { MainActor.assumeIsolated { log.append(chunk) } }
            })
            self.finishBrainRun(id: id, outcome: outcome)
        }
    }

    /// "Zrušit": terminates Copilot CLI; the run does not count as successful.
    func cancelBrainRun() {
        guard brainRunPhase == .running, let task = brainRunTask else { return }
        brainRunPhase = .cancelling
        brainRunLog.append("\nRuším…\n")
        task.cancel()
    }

    /// On quit: stops Copilot CLI right away.
    func terminateBrainRun() {
        brainRunTask?.cancel()
    }

    /// A new Vault starts with no run; a run of the previous Vault is cancelled and reports nothing.
    func resetBrainRun(for vault: Vault) {
        brainRunTask?.cancel()
        brainRunTask = nil
        brainRun = nil
        brainRunID = UUID()
        brainRunPhase = .idle
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

    /// Tells the running Brain Run which files the user's last save wrote.
    func acceptUserWriteDuringBrainRun(of document: NoteDocument) {
        guard let brainRun, let vault else { return }
        let paths = document.lastSaveWrittenFileURLs.compactMap { relativePath(for: $0, in: vault) }
        guard !paths.isEmpty else { return }
        brainRun.acceptUserWrite(under: paths)
    }

    /// Outside changes during a run: if a file outside `_brain/` changed without
    /// the user saving it, stop the Agent at once; the run then fails with the list.
    func checkBrainRunBoundary(after change: VaultChange) {
        guard let brainRun, brainRunPhase == .running,
              change.requiresFullRescan
                || change.relativePaths.contains(where: { !VaultFileSnapshot.isInBrainFolder($0) })
        else { return }
        guard !isCheckingBrainRunBoundary else {
            needsBrainRunBoundaryRecheck = true
            return
        }
        isCheckingBrainRunBoundary = true
        needsBrainRunBoundaryRecheck = false
        let id = brainRunID
        Task { [weak self] in
            let outside = await Task.detached { brainRun.changesOutsideBrain() }.value
            guard let self else { return }
            self.isCheckingBrainRunBoundary = false
            guard self.brainRunID == id, self.brainRunPhase == .running else { return }
            if !outside.isEmpty {
                self.brainRunLog.append("\nZměna mimo _brain/: \(outside.joined(separator: ", ")). Zastavuji Agenta.\n")
                self.cancelBrainRun()
            } else if self.needsBrainRunBoundaryRecheck {
                self.checkBrainRunBoundary(after: VaultChange(relativePaths: [], requiresFullRescan: true))
            }
        }
    }

    private func finishBrainRun(id: UUID, outcome: BrainRunOutcome) {
        switch outcome {
        case .succeeded(let processed):
            guard brainRunID == id else { return }
            lastSuccessfulBrainRun = Date()
            endBrainRun(.succeeded(processed: processed), logLine: "Hotovo: zpracováno poznámek: \(processed).")
        case .nothingToProcess:
            endBrainRun(id: id, .nothingToProcess, logLine: "Hotovo: od posledního zpracování se nic nezměnilo.")
        case .cancelled:
            endBrainRun(id: id, .cancelled, logLine: "Zrušeno. Běh se nepočítá jako úspěšný.")
        case .failed(let failure):
            let alert: Bool
            switch failure {
            case .changedOutsideBrain, .launch, .brainFolderUnavailable: alert = true
            default: alert = false
            }
            finishBrainRun(id: id, failure: Self.message(for: failure), alert: alert)
        }
    }

    private func finishBrainRun(id: UUID, failure message: String, alert: Bool) {
        endBrainRun(id: id, .failed(message), logLine: "Chyba: \(message)")
        if alert, brainRunID == id {
            errorMessage = message
        }
    }

    private func endBrainRun(id: UUID, _ phase: BrainRunPhase, logLine: String) {
        guard brainRunID == id else { return }
        endBrainRun(phase, logLine: logLine)
    }

    private func endBrainRun(_ phase: BrainRunPhase, logLine: String) {
        brainRun = nil
        brainRunTask = nil
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
        }
    }
}
