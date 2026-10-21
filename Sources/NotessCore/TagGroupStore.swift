import CryptoKit
import Foundation

/// Persists a Vault's Tag Groups on this Mac, outside the Vault and apart
/// from the disposable search index, in
/// `~/Library/Application Support/Notess/TagGroups/<hash of the Vault path>.json`.
/// Rebuilding the index never touches it, and it is not synchronised between devices.
public struct TagGroupStore: Sendable {
    public let directoryURL: URL

    public init(directoryURL: URL = TagGroupStore.defaultDirectoryURL) {
        self.directoryURL = directoryURL
    }

    public static var defaultDirectoryURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Notess/TagGroups", directoryHint: .isDirectory)
    }

    /// The Vault's Tag Groups; none if it has never had any.
    public func groups(for vault: Vault) throws -> TagGroups {
        let url = fileURL(for: vault)
        guard FileManager.default.fileExists(atPath: url.path) else { return TagGroups() }
        let stored = try JSONDecoder().decode(StoredGroups.self, from: Data(contentsOf: url))
        guard stored.version == StoredGroups.currentVersion else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return TagGroups(groups: stored.groups)
    }

    public func remember(_ groups: TagGroups, for vault: Vault) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let stored = StoredGroups(
            version: StoredGroups.currentVersion,
            vaultPath: vault.rootURL.path(percentEncoded: false),
            groups: groups.groups
        )
        try encoder.encode(stored).write(to: fileURL(for: vault), options: .atomic)
    }

    private func fileURL(for vault: Vault) -> URL {
        let digest = SHA256.hash(data: Data(vault.rootURL.path(percentEncoded: false).utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return directoryURL.appending(path: "\(name).json", directoryHint: .notDirectory)
    }
}

private struct StoredGroups: Codable {
    static let currentVersion = 1

    let version: Int
    /// For a person looking at the file; the file name already identifies the Vault.
    let vaultPath: String
    let groups: [TagGroup]
}
