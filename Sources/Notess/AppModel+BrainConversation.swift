import Foundation
import NotessCore
import Observation

/// Creates the ACP connection for a Brain Conversation in a Vault; tests substitute it.
typealias BrainConversationConnectionFactory = @MainActor (Vault, _ executable: URL) -> any ACPConnection

extension CopilotACPConnection {
    @MainActor static let factory: BrainConversationConnectionFactory = { vault, executable in
        CopilotACPConnection(vault: vault, configuration: .init(executableURL: executable))
    }
}

/// The open Vault's Brain Conversation. Kept apart from `AppModel` so a streaming
/// answer re-renders only the panel, never the editor.
@MainActor
@Observable
final class BrainConversationState {
    var conversation = BrainConversation() {
        didSet {
            let active = conversation.activeTurn != nil
            if active != isTurnActive { isTurnActive = active }
        }
    }

    /// Whether a turn is running or stopping; changes only when a turn starts or ends.
    private(set) var isTurnActive = false
    /// Why a question was not sent, shown by the input.
    var refusal: String?
}

extension AppModel {
    /// "Zeptat se": sends a question about the saved Vault, or a follow-up in the same
    /// conversation. Returns `false` when it was not sent; `brainConversation.refusal`
    /// then says why.
    @discardableResult
    func askBrainConversation(_ text: String) -> Bool {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = brainConversation
        guard let vault, !question.isEmpty, !state.isTurnActive else { return false }
        guard !agentOperations.isOccupied else {
            state.refusal = isBrainRunActive
                ? "Běží Brain Run. Zeptat se můžete, až doběhne."
                : "Agent ještě dokončuje předchozí práci. Zkuste to za chvíli."
            return false
        }
        guard let turnID = state.conversation.begin(question: question, at: now()) else { return false }
        state.refusal = nil
        let conversationID = state.conversation.id
        let configuredPath = settings.copilotCLIPath
        brainConversationOperation = agentOperations.begin(.conversationTurn, in: vault) { [weak self] operation in
            await self?.runBrainConversationTurn(
                operation, turnID: turnID, conversationID: conversationID,
                question: question, configuredPath: configuredPath
            )
        }
        return true
    }

    /// "Zastavit": asks the Agent to stop the turn; it is marked incomplete once it ends.
    func stopBrainConversationTurn() {
        guard let turn = brainConversation.conversation.activeTurn, turn.state == .running,
              let operation = brainConversationOperation
        else { return }
        brainConversation.conversation.markStopping(turn.id)
        agentOperations.cancel(operation)
    }

    /// A new Vault starts with an empty conversation. A running turn is stopped by the
    /// boundary and closes its own Agent. The Agent kept between turns is closed as a
    /// cleanup even while a turn runs: that turn may not have picked it up yet.
    func resetBrainConversation() {
        closeKeptBrainConversationConnection()
        brainConversationOperation = nil
        brainConversation.conversation = BrainConversation()
        brainConversation.refusal = nil
    }

    /// Closes the Agent kept between turns unless a turn is using it. A running turn
    /// closes its Agent itself once it is stale or the Vault is left.
    func closeIdleBrainConversation() {
        guard brainConversationOperation == nil else { return }
        closeKeptBrainConversationConnection()
    }

    /// Closes the kept Agent as a cleanup that keeps the shared boundary occupied until
    /// its process group is gone.
    private func closeKeptBrainConversationConnection() {
        guard let connection = brainConversationConnection, let vault else { return }
        brainConversationConnection = nil
        agentOperations.cleanUp(.conversationTurn, in: vault) {
            await connection.close()
        }
    }

    /// Closes `connection` and forgets it if it is still the kept Agent.
    private func closeBrainConversationConnection(_ connection: any ACPConnection) async {
        await connection.close()
        if brainConversationConnection === connection { brainConversationConnection = nil }
    }

    /// Whether quitting must wait for an Agent process: an operation or an idle conversation.
    var ownsAgentProcesses: Bool {
        agentOperations.isOccupied || brainConversationConnection != nil
    }

    private func runBrainConversationTurn(
        _ operation: AgentOperationBoundary.Operation,
        turnID: UUID,
        conversationID: UUID,
        question: String,
        configuredPath: String?
    ) async {
        let state = brainConversation
        let now = self.now
        /// Changes the conversation only while this turn still reports to the user.
        let report: @MainActor (_ change: (inout BrainConversation) -> Void) -> Void = { change in
            guard !operation.isStale, state.conversation.id == conversationID else { return }
            change(&state.conversation)
        }
        defer {
            if brainConversationOperation === operation { brainConversationOperation = nil }
        }

        let resolution = await Task.detached {
            CopilotCLILocator().resolve(configuredPath: configuredPath)
        }.value
        guard case .found(let executable) = resolution else {
            report { $0.fail(turnID, message: Self.cliMessage(for: resolution), at: now()) }
            return
        }
        if Task.isCancelled {
            report { $0.stop(turnID, at: now()) }
            return
        }

        var connection = operation.isStale ? nil : brainConversationConnection
        if let existing = connection, !(await existing.isOpen()) {
            await closeBrainConversationConnection(existing)
            connection = nil
            report { $0.note("Předchozí relace Agenta skončila; pokračuje nová relace bez dřívějšího kontextu.", in: turnID) }
        }
        let isNewSession = connection == nil
        let active: any ACPConnection
        if let connection {
            active = connection
        } else {
            guard !operation.isStale else { return }
            active = makeBrainConversationConnection(operation.vault, executable)
            brainConversationConnection = active
            report { $0.note("Spouštím Agenta; zápis do Vaultu je zablokovaný.", in: turnID) }
            do {
                try await active.start()
            } catch {
                await closeBrainConversationConnection(active)
                if Task.isCancelled {
                    report { $0.stop(turnID, at: now()) }
                } else {
                    report { $0.fail(turnID, message: Self.message(for: error), at: now()) }
                }
                return
            }
        }

        let blocks = BrainConversationInstructions.promptBlocks(question: question, isFirstInSession: isNewSession)
        let result: Result<ACPStopReason, BrainConversationError>
        do {
            result = .success(try await active.prompt(blocks) { event in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { report { $0.apply(event, to: turnID) } }
                }
            })
        } catch {
            result = .failure(error)
        }
        // Events queued before `session/prompt` answered are applied before the turn ends.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        let stillOpen = await active.isOpen()
        if operation.isStale || !stillOpen || result.isFailure {
            await closeBrainConversationConnection(active)
        }
        switch result {
        case .success(let stopReason):
            report { $0.finish(turnID, stopReason: stopReason, at: now()) }
        case .failure(let error):
            report { $0.fail(turnID, message: Self.message(for: error), at: now()) }
        }
    }

    static func message(for error: BrainConversationError) -> String {
        let refused = "Agent nebyl spuštěn."
        switch error {
        case .sandbox(.unavailable(let detail)):
            return "Ochranu Vaultu proti zápisu (sandbox-exec) nelze použít: \(detail) \(refused)"
        case .sandbox(.ineffective):
            return "Ochrana Vaultu nezabránila zkušebnímu zápisu do Vaultu. \(refused)"
        case .sandbox(.vaultUnresolvable(let detail)):
            return "Skutečnou cestu k Vaultu se nepodařilo zjistit: \(detail) \(refused)"
        case .sandbox(.outsideHardLinks(let paths)):
            let shown = paths.prefix(5).joined(separator: ", ")
            let more = paths.count > 5 ? " a další (\(paths.count - 5))" : ""
            return "Soubory \(shown)\(more) mají pevné odkazy (hard links) mimo Vault, přes které by do nich šlo zapisovat. \(refused)"
        case .launch(let detail):
            return "Copilot CLI se nepodařilo spustit: \(detail)"
        case .authentication(let detail):
            return "Copilot CLI není přihlášený. Spusťte v Terminálu „copilot“ a přihlaste se příkazem /login. \(detail)"
        case .protocolViolation(let detail):
            return "Copilot CLI odpověděl neočekávaně: \(detail)"
        case .agent(let detail):
            return "Copilot CLI ohlásil chybu: \(detail)"
        case .exited(let status, let detail):
            let tail = detail.isEmpty ? "" : " \(detail)"
            return "Copilot CLI se neočekávaně ukončil (kód \(status)).\(tail)"
        }
    }

    static func cliMessage(for resolution: CopilotCLIResolution) -> String {
        switch resolution {
        case .found:
            return ""
        case .configuredPathUnavailable(let path):
            return "Copilot CLI na cestě z Nastavení (\(path)) nebyl nalezen nebo není spustitelný. Opravte cestu v Nastavení (⌘,)."
        case .notFound:
            return "Copilot CLI nebyl nalezen. Nainstalujte GitHub Copilot CLI, nebo zadejte cestu k němu v Nastavení (⌘,)."
        }
    }
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
