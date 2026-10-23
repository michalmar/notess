import CryptoKit
import Foundation

/// Why a Vault's Brain Conversation history could not be read or written. History that
/// cannot be read is never replaced silently.
public enum BrainConversationStoreError: Error, Equatable, Sendable, LocalizedError {
    /// The file exists but could not be read.
    case unreadable(path: String, detail: String)
    /// The file is not valid history.
    case malformed(path: String, detail: String)
    /// Written by a newer Notess; opening it with this version would lose data.
    case unsupportedVersion(Int, path: String)
    /// The file belongs to a different Vault.
    case otherVault(path: String, storedVaultPath: String)
    case writeFailed(path: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path, let detail):
            return "Soubor historie konverzace nelze přečíst (\(path)): \(detail)"
        case .malformed(let path, let detail):
            return "Soubor historie konverzace je poškozený (\(path)): \(detail)"
        case .unsupportedVersion(let version, let path):
            return "Historii konverzace (\(path)) uložila novější verze Notess (formát \(version))."
        case .otherVault(let path, let stored):
            return "Soubor historie konverzace (\(path)) patří jinému Vaultu (\(stored))."
        case .writeFailed(let path, let detail):
            return "Historii konverzace se nepodařilo uložit (\(path)): \(detail)"
        }
    }
}

/// Persists a Vault's Brain Conversation outside the Vault, in
/// `~/Library/Application Support/Notess/BrainConversations/<hash of the Vault path>.json`,
/// independently of the Brain Run success record (`BrainRunStateStore`).
///
/// The file is versioned and holds a list of conversations with the id of the current
/// one, so several conversations per Vault need no new format; today exactly one is
/// read and written. Unknown fields are ignored on read.
public struct BrainConversationStore: Sendable {
    public static let currentVersion = 1

    public let directoryURL: URL

    public init(directoryURL: URL = BrainConversationStore.defaultDirectoryURL) {
        self.directoryURL = directoryURL
    }

    public static var defaultDirectoryURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Notess/BrainConversations", directoryHint: .isDirectory)
    }

    /// The Vault's conversation as stored, or `nil` when none was saved. Turns that were
    /// still running when it was saved come back incomplete and interrupted.
    public func load(for vault: Vault) throws(BrainConversationStoreError) -> BrainConversation? {
        guard let file = try readFile(for: vault) else { return nil }
        let records = file.conversations
        let record = records.first { $0.id == file.currentConversationID } ?? records.first
        guard let record else { return nil }
        var conversation = record.conversation()
        conversation.interruptActiveTurn(at: record.updatedAt)
        return conversation
    }

    /// Saves `conversation` as the Vault's current one, keeping any other conversations
    /// already in the file. Refuses to overwrite a file it cannot read.
    public func save(_ conversation: BrainConversation, at date: Date, for vault: Vault) throws(BrainConversationStoreError) {
        var file = try readFile(for: vault) ?? StoredFile(vaultPath: Self.path(of: vault))
        let record = StoredConversation(conversation, updatedAt: date)
        if let index = file.conversations.firstIndex(where: { $0.id == record.id }) {
            file.conversations[index] = record
        } else {
            file.conversations.append(record)
        }
        file.currentConversationID = record.id
        file.version = Self.currentVersion

        let url = fileURL(for: vault)
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(file).write(to: url, options: .atomic)
        } catch {
            throw .writeFailed(path: url.path(percentEncoded: false), detail: error.localizedDescription)
        }
    }

    /// Moves a history that cannot be read aside, so a fresh conversation can start
    /// without destroying it. Returns where it went.
    @discardableResult
    public func setUnreadableHistoryAside(for vault: Vault, at date: Date) throws(BrainConversationStoreError) -> URL? {
        let url = fileURL(for: vault)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        let stamp = Int(date.timeIntervalSince1970)
        let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: url, to: aside)
        } catch {
            throw .writeFailed(path: url.path(percentEncoded: false), detail: error.localizedDescription)
        }
        return aside
    }

    func fileURL(for vault: Vault) -> URL {
        let digest = SHA256.hash(data: Data(Self.path(of: vault).utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return directoryURL.appending(path: "\(name).json", directoryHint: .notDirectory)
    }

    private static func path(of vault: Vault) -> String {
        vault.rootURL.path(percentEncoded: false)
    }

    private func readFile(for vault: Vault) throws(BrainConversationStoreError) -> StoredFile? {
        let url = fileURL(for: vault)
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .unreadable(path: path, detail: error.localizedDescription)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // The version is read first so a newer format is reported as such, not as malformed.
        let header: Header
        do {
            header = try decoder.decode(Header.self, from: data)
        } catch {
            throw .malformed(path: path, detail: Self.describe(error))
        }
        guard header.version <= Self.currentVersion else { throw .unsupportedVersion(header.version, path: path) }
        let file: StoredFile
        do {
            file = try decoder.decode(StoredFile.self, from: data)
        } catch {
            throw .malformed(path: path, detail: Self.describe(error))
        }
        guard file.vaultPath == Self.path(of: vault) else {
            throw .otherVault(path: path, storedVaultPath: file.vaultPath)
        }
        return file
    }

    private static func describe(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case .keyNotFound(let key, _): return "chybí položka „\(key.stringValue)“"
            case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
                let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
            @unknown default: break
            }
        }
        return error.localizedDescription
    }

    private struct Header: Decodable {
        let version: Int
    }
}

// MARK: Stored form

/// The file's content. Separate from the in-memory conversation so that new fields on
/// either side do not break reading older files: every field beyond the essentials is
/// optional on read.
private struct StoredFile: Codable {
    var version = BrainConversationStore.currentVersion
    var vaultPath: String
    var currentConversationID: UUID?
    var conversations: [StoredConversation] = []

    init(vaultPath: String) {
        self.vaultPath = vaultPath
    }
}

private struct StoredConversation: Codable {
    var id: UUID
    var updatedAt: Date
    var acpSessionID: String?
    var sessionHasInstructions: Bool?
    var turns: [StoredTurn]

    init(_ conversation: BrainConversation, updatedAt: Date) {
        id = conversation.id
        self.updatedAt = updatedAt
        acpSessionID = conversation.sessionID
        sessionHasInstructions = conversation.sessionHasInstructions
        turns = conversation.turns.map(StoredTurn.init)
    }

    func conversation() -> BrainConversation {
        BrainConversation(
            id: id,
            turns: turns.map { $0.turn() },
            sessionID: acpSessionID,
            sessionHasInstructions: sessionHasInstructions ?? false
        )
    }
}

private struct StoredTurn: Codable {
    var id: UUID
    var question: String
    var answer: String?
    var activity: [StoredActivity]?
    var state: StoredState
    var startedAt: Date
    var finishedAt: Date?

    init(_ turn: BrainConversation.Turn) {
        id = turn.id
        question = turn.question
        answer = turn.answer
        activity = turn.activity.map(StoredActivity.init)
        state = StoredState(turn.state)
        startedAt = turn.startedAt
        finishedAt = turn.finishedAt
    }

    func turn() -> BrainConversation.Turn {
        BrainConversation.Turn(
            id: id,
            question: question,
            answer: answer ?? "",
            activity: (activity ?? []).map { $0.activity() },
            state: state.turnState(),
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }
}

private struct StoredState: Codable {
    var kind: String
    var message: String?

    init(_ state: BrainConversation.TurnState) {
        switch state {
        case .running: kind = "running"
        case .stopping: kind = "stopping"
        case .completed: kind = "completed"
        case .incomplete(let reason): (kind, message) = ("incomplete", reason)
        case .failed(let text): (kind, message) = ("failed", text)
        }
    }

    /// A state this version does not know is shown as incomplete rather than completed.
    func turnState() -> BrainConversation.TurnState {
        switch kind {
        case "running": .running
        case "stopping": .stopping
        case "completed": .completed
        case "failed": .failed(message ?? "")
        default: .incomplete(reason: message)
        }
    }
}

private struct StoredActivity: Codable {
    var id: String
    var title: String
    var kind: String
    var toolKind: String?
    var status: String?
    var option: String?

    init(_ activity: BrainConversation.Activity) {
        id = activity.id
        title = activity.title
        switch activity.kind {
        case .tool(let kind, let status): (self.kind, toolKind, self.status) = ("tool", kind, status.rawValue)
        case .permission(let option): (kind, self.option) = ("permission", option)
        case .notice: kind = "notice"
        }
    }

    func activity() -> BrainConversation.Activity {
        let kind: BrainConversation.Activity.Kind
        switch self.kind {
        case "tool":
            kind = .tool(kind: toolKind, status: status.flatMap(ACPToolCallStatus.init(rawValue:)) ?? .pending)
        case "permission":
            kind = .permission(option: option ?? "")
        default:
            kind = .notice
        }
        return BrainConversation.Activity(id: id, title: title, kind: kind)
    }
}
