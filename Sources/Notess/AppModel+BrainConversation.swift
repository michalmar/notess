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

/// The open Vault's Brain Conversations. Kept apart from `AppModel` so a streaming
/// answer re-renders only the panel, never the editor.
@MainActor
@Observable
final class BrainConversationState {
    var conversations = [BrainConversation()] {
        didSet {
            let active = conversations.contains { $0.activeTurn != nil }
            if active != isTurnActive { isTurnActive = active }
        }
    }
    var selectedIndex = 0
    var conversation: BrainConversation {
        get { conversations[selectedIndex] }
        set { conversations[selectedIndex] = newValue }
    }
    var activeConversation: BrainConversation? { conversations.first { $0.activeTurn != nil } }

    func updateConversation(_ id: UUID, _ change: (inout BrainConversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        change(&conversations[index])
    }

    /// Explicitly created empty conversations and their selection also survive restart.
    var hasSavedHistory = false
    /// Closing an idle Agent still owns the shared operation boundary.
    var connectionCleanups = 0
    var isConnectionClosing: Bool { connectionCleanups > 0 }

    /// Whether a turn is running or stopping; changes only when a turn starts or ends.
    private(set) var isTurnActive = false
    /// Why a question was not sent, shown by the input.
    var refusal: String?
    /// Why the saved history could not be read. It is left untouched and no question is
    /// accepted until the user starts a new conversation on purpose.
    var historyFailure: String?
    /// Why the conversation could not be saved: it is then not durable.
    var persistenceFailure: String?
    /// Why the saved Agent session could not be loaded. The history stays; the Agent has
    /// no context for it until the user continues without it on purpose.
    var resumeFailures: [UUID: String] = [:]
    var resumeFailure: String? {
        get { resumeFailures[conversation.id] }
        set { resumeFailures[conversation.id] = newValue }
    }
    /// The user chose to continue without the earlier Agent context; the next turn says so.
    var discardedContexts: Set<UUID> = []
    var contextWasDiscarded: Bool {
        get { discardedContexts.contains(conversation.id) }
        set {
            if newValue { discardedContexts.insert(conversation.id) }
            else { discardedContexts.remove(conversation.id) }
        }
    }
}

extension AppModel {
    /// Starts an unrelated conversation without inheriting an Agent session or transcript.
    @discardableResult
    func createBrainConversation() -> Bool {
        let state = brainConversation
        guard vault != nil, state.historyFailure == nil else { return false }
        if !state.isTurnActive { closeKeptBrainConversationConnection() }
        let conversation = BrainConversation()
        state.conversations.append(conversation)
        state.selectedIndex = state.conversations.count - 1
        state.hasSavedHistory = true
        state.refusal = nil
        persistBrainConversation()
        return true
    }

    /// Selects saved history without starting an Agent operation.
    @discardableResult
    func selectBrainConversation(_ id: UUID) -> Bool {
        let state = brainConversation
        guard state.historyFailure == nil,
              let index = state.conversations.firstIndex(where: { $0.id == id })
        else { return false }
        guard index != state.selectedIndex else { return true }
        if !state.isTurnActive { closeKeptBrainConversationConnection() }
        state.selectedIndex = index
        state.refusal = nil
        persistBrainConversation()
        return true
    }

    /// "Zeptat se": sends a question about the saved Vault, or a follow-up in the same
    /// conversation. Returns `false` when it was not sent; `brainConversation.refusal`
    /// then says why.
    @discardableResult
    func askBrainConversation(_ text: String) -> Bool {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = brainConversation
        guard let vault, !question.isEmpty, !state.isTurnActive else { return false }
        guard state.historyFailure == nil else {
            state.refusal = "Uloženou historii konverzace nelze přečíst, proto se nic neodešle ani nepřepíše. Začněte novou konverzaci tlačítkem výše."
            return false
        }
        guard !agentOperations.isOccupied else {
            state.refusal = isBrainRunActive
                ? "Běží Brain Run. Zeptat se můžete, až doběhne."
                : "Agent ještě dokončuje předchozí práci. Zkuste to za chvíli."
            return false
        }
        guard let turnID = state.conversation.begin(question: question, at: now()) else { return false }
        state.refusal = nil
        persistBrainConversation()
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
        let state = brainConversation
        guard let conversation = state.activeConversation,
              let turn = conversation.activeTurn, turn.state == .running,
              let operation = brainConversationOperation
        else { return }
        state.updateConversation(conversation.id) { $0.markStopping(turn.id) }
        agentOperations.cancel(operation)
    }

    /// A new Vault starts with an empty conversation. A running turn is stopped by the
    /// boundary and closes its own Agent. The Agent kept between turns is closed as a
    /// cleanup even while a turn runs: that turn may not have picked it up yet.
    func resetBrainConversation() {
        persistBrainConversationBeforeLeaving()
        closeKeptBrainConversationConnection()
        brainConversationOperation = nil
        let state = brainConversation
        state.selectedIndex = 0
        state.conversations = [BrainConversation()]
        state.hasSavedHistory = false
        state.refusal = nil
        state.historyFailure = nil
        state.persistenceFailure = nil
        state.resumeFailures = [:]
        state.discardedContexts = []
    }

    /// Shows the Vault's saved conversation. A turn that was running when Notess ended
    /// comes back incomplete; history that cannot be read is reported and left as it is.
    func restoreBrainConversation(for vault: Vault) {
        do {
            if let history = try brainConversationStore.loadHistory(for: vault), !history.conversations.isEmpty {
                brainConversation.conversations = history.conversations
                brainConversation.selectedIndex = history.conversations.firstIndex {
                    $0.id == history.currentConversationID
                } ?? 0
                brainConversation.hasSavedHistory = true
            }
        } catch {
            brainConversation.historyFailure = error.localizedDescription
        }
    }

    /// "Začít novou konverzaci" after unreadable history: the old file is moved aside,
    /// never overwritten.
    func startNewBrainConversationAfterUnreadableHistory() {
        guard let vault, brainConversation.historyFailure != nil, !brainConversation.isTurnActive else { return }
        do {
            let aside = try brainConversationStore.setUnreadableHistoryAside(for: vault, at: now())
            brainConversation.historyFailure = nil
            brainConversation.persistenceFailure = nil
            brainConversation.conversation = BrainConversation()
            if let aside {
                brainConversation.refusal = "Nečitelná historie byla přesunuta do \(aside.path(percentEncoded: false))."
            }
        } catch {
            brainConversation.historyFailure = error.localizedDescription
        }
    }

    /// "Pokračovat bez kontextu" after the saved Agent session could not be loaded: the
    /// transcript stays, the next question opens a new Agent session without earlier context.
    func continueBrainConversationWithoutContext() {
        let state = brainConversation
        guard vault != nil, !state.isTurnActive, state.resumeFailure != nil else { return }
        closeKeptBrainConversationConnection()
        state.conversation.discardSession()
        state.resumeFailure = nil
        state.contextWasDiscarded = true
        persistBrainConversation()
    }

    /// Saves the open Vault's conversation now. A failure is shown in the panel, so an
    /// unsaved transcript is never presented as durable.
    func persistBrainConversation() {
        brainConversationCheckpoint?.cancel()
        brainConversationCheckpoint = nil
        let state = brainConversation
        guard let vault, state.historyFailure == nil,
              state.hasSavedHistory || state.conversations.contains(where: \.hasContent)
        else { return }
        do {
            try brainConversationStore.save(
                state.conversations, currentConversationID: state.conversation.id, at: now(), for: vault
            )
            state.hasSavedHistory = true
            state.persistenceFailure = nil
        } catch {
            state.persistenceFailure = error.localizedDescription
        }
    }

    /// Saves a streaming turn at most every half second, so a crash keeps most of the
    /// partial answer without writing on every chunk.
    private func scheduleBrainConversationCheckpoint() {
        guard brainConversationCheckpoint == nil else { return }
        brainConversationCheckpoint = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            self.persistBrainConversation()
        }
    }

    /// Vault switch and quit: work that is still active is stopped, so it is saved as
    /// incomplete, and the history of the Vault being left is written before anything else.
    func persistBrainConversationBeforeLeaving() {
        let state = brainConversation
        if let conversation = state.activeConversation, let turn = conversation.activeTurn {
            state.updateConversation(conversation.id) { $0.stop(turn.id, at: now()) }
        }
        brainConversationCheckpoint?.cancel()
        brainConversationCheckpoint = nil
        guard let vault, state.historyFailure == nil,
              state.hasSavedHistory || state.conversations.contains(where: \.hasContent)
        else { return }
        do {
            try brainConversationStore.save(
                state.conversations, currentConversationID: state.conversation.id, at: now(), for: vault
            )
        } catch {
            errorMessage = "Historii konverzace se nepodařilo uložit: \(error.localizedDescription)"
        }
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
        brainConversationConnectionID = nil
        let state = brainConversation
        state.connectionCleanups += 1
        agentOperations.cleanUp(.conversationTurn, in: vault) {
            await connection.close()
            state.connectionCleanups -= 1
        }
    }

    /// Closes `connection` and forgets it if it is still the kept Agent.
    private func closeBrainConversationConnection(_ connection: any ACPConnection) async {
        await connection.close()
        if brainConversationConnection === connection {
            brainConversationConnection = nil
            brainConversationConnectionID = nil
        }
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
        guard let conversation = state.conversations.first(where: { $0.id == conversationID }) else { return }
        let now = self.now
        /// Changes the conversation only while this turn still reports to the user, then
        /// saves it: at once when the turn ended or `immediately`, else as a checkpoint.
        let report: @MainActor (_ immediately: Bool, _ change: (inout BrainConversation) -> Void) -> Void = { [weak self] immediately, change in
            guard !operation.isStale,
                  state.conversations.first(where: { $0.id == conversationID })?.activeTurn?.id == turnID
            else { return }
            state.updateConversation(conversationID, change)
            if immediately || !state.isTurnActive {
                self?.persistBrainConversation()
            } else {
                self?.scheduleBrainConversationCheckpoint()
            }
        }
        defer {
            if brainConversationOperation === operation { brainConversationOperation = nil }
        }

        let resolution = await Task.detached {
            CopilotCLILocator().resolve(configuredPath: configuredPath)
        }.value
        guard case .found(let executable) = resolution else {
            report(true) { $0.fail(turnID, message: Self.cliMessage(for: resolution), at: now()) }
            return
        }
        if Task.isCancelled {
            report(true) { $0.stop(turnID, at: now()) }
            return
        }

        var connection = !operation.isStale && brainConversationConnectionID == conversationID
            ? brainConversationConnection : nil
        if let existing = connection, !(await existing.isOpen()) {
            await closeBrainConversationConnection(existing)
            connection = nil
        }
        // A new Agent process continues the saved session when there is one; the sandbox
        // check and launch checks run again, exactly as for a new session.
        let resumedSession = connection == nil ? conversation.sessionID : nil
        let hasInstructions = connection != nil || resumedSession != nil && conversation.sessionHasInstructions
        let active: any ACPConnection
        if let connection {
            active = connection
        } else {
            guard !operation.isStale else { return }
            active = makeBrainConversationConnection(operation.vault, executable)
            brainConversationConnection = active
            brainConversationConnectionID = conversationID
            report(false) {
                $0.note(
                    resumedSession == nil
                        ? "Spouštím Agenta; zápis do Vaultu je zablokovaný."
                        : "Spouštím Agenta a obnovuji uloženou relaci; zápis do Vaultu je zablokovaný.",
                    in: turnID
                )
            }
            do {
                try await active.start(resuming: resumedSession)
            } catch {
                await closeBrainConversationConnection(active)
                if Task.isCancelled {
                    report(true) { $0.stop(turnID, at: now()) }
                } else {
                    if resumedSession != nil, !operation.isStale, Self.isSessionLoadFailure(error) {
                        state.resumeFailures[conversationID] = Self.message(for: error)
                    }
                    report(true) { $0.fail(turnID, message: Self.message(for: error), at: now()) }
                }
                return
            }
            if !operation.isStale { state.resumeFailures[conversationID] = nil }
            if resumedSession != nil {
                report(false) { $0.note("Pokračuji v uložené relaci Agenta.", in: turnID) }
            } else if state.discardedContexts.contains(conversationID), !operation.isStale {
                state.discardedContexts.remove(conversationID)
                report(false) { $0.note("Nová relace Agenta bez kontextu dřívějších zpráv.", in: turnID) }
            }
        }

        let blocks = BrainConversationInstructions.promptBlocks(question: question, isFirstInSession: !hasInstructions)
        let sessionID = active.sessionID
        // The instructions count as delivered only once the Agent has reacted to the prompt.
        report(true) { $0.attach(sessionID: sessionID, hasInstructions: hasInstructions) }
        let result: Result<ACPStopReason, BrainConversationError>
        do {
            result = .success(try await active.prompt(blocks) { event in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        report(false) {
                            $0.attach(sessionID: sessionID, hasInstructions: true)
                            $0.apply(event, to: turnID)
                        }
                    }
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
        if operation.isStale || state.conversation.id != conversationID || !stillOpen || result.isFailure {
            await closeBrainConversationConnection(active)
        }
        switch result {
        case .success(let stopReason):
            report(true) {
                $0.attach(sessionID: sessionID, hasInstructions: true)
                $0.finish(turnID, stopReason: stopReason, at: now())
            }
        case .failure(let error):
            report(true) { $0.fail(turnID, message: Self.message(for: error), at: now()) }
        }
    }

    /// Whether the CLI itself said the saved session cannot be loaded. A crash, timeout
    /// or failed check says nothing about the session, so those are only retried.
    private static func isSessionLoadFailure(_ error: BrainConversationError) -> Bool {
        if case .sessionUnavailable = error { return true }
        return false
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
        case .sessionUnavailable(let detail):
            return "Uloženou relaci Agenta se nepodařilo načíst: \(detail) Historie zůstává zobrazená, ale Agent její kontext nemá. Zkuste to znovu, nebo pokračujte v nové relaci bez dřívějšího kontextu."
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
