import CryptoKit
import Foundation

/// The last successful Brain Run of a Vault: when it finished and what the
/// files outside `_brain/` looked like when it started.
public struct BrainRunRecord: Codable, Equatable, Sendable {
    public let completedAt: Date
    public let snapshot: VaultFileSnapshot

    public init(completedAt: Date, snapshot: VaultFileSnapshot) {
        self.completedAt = completedAt
        self.snapshot = snapshot
    }
}

/// Persists the last successful Brain Run per Vault, outside the Vault in
/// `~/Library/Application Support/Notess/BrainRuns/<hash of the Vault path>.json`.
/// Losing it only means the next Brain Run processes every note again.
public struct BrainRunStateStore: Sendable {
    public let directoryURL: URL

    public init(directoryURL: URL = BrainRunStateStore.defaultDirectoryURL) {
        self.directoryURL = directoryURL
    }

    public static var defaultDirectoryURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Notess/BrainRuns", directoryHint: .isDirectory)
    }

    public func lastSuccessfulRun(for vault: Vault) throws -> BrainRunRecord? {
        let url = fileURL(for: vault)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BrainRunRecord.self, from: Data(contentsOf: url))
    }

    public func rememberSuccessfulRun(_ record: BrainRunRecord, for vault: Vault) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: fileURL(for: vault), options: .atomic)
    }

    private func fileURL(for vault: Vault) -> URL {
        let digest = SHA256.hash(data: Data(vault.rootURL.path(percentEncoded: false).utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return directoryURL.appending(path: "\(name).json", directoryHint: .notDirectory)
    }
}
