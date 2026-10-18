import CryptoKit
import Foundation

/// A file or folder outside `_brain/` that exists but could not be listed or read,
/// so a snapshot would be incomplete.
public struct VaultSnapshotError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Vault-relative path of the unreadable file or folder (`""` is the Vault itself).
    public let relativePath: String
    /// The system's reason.
    public let detail: String

    public init(relativePath: String, detail: String) {
        self.relativePath = relativePath
        self.detail = detail
    }

    public var description: String {
        "Could not read \(relativePath.isEmpty ? "the Vault" : relativePath): \(detail)"
    }
}

/// What every file outside `_brain/` looked like at one moment: the basis for
/// choosing the notes a Brain Run processes and for noticing that something
/// other than the user changed the user's files during a run.
///
/// Notes are fingerprinted by content (a rewrite with the same text is no
/// change); other files, such as attachments, by size and modification date.
/// Hidden items (`.git`, `.DS_Store`) and symlinks are left out.
///
/// A capture is complete or fails: a file or folder that exists but cannot be
/// listed or read throws `VaultSnapshotError` rather than being left out, since
/// a missing fingerprint means the file is gone.
public struct VaultFileSnapshot: Codable, Equatable, Sendable {
    /// Vault-relative path → fingerprint.
    public var fingerprints: [String: String]

    public init(fingerprints: [String: String] = [:]) {
        self.fingerprints = fingerprints
    }

    public static func capture(of vault: Vault) throws(VaultSnapshotError) -> VaultFileSnapshot {
        try capture(of: vault, under: "")
    }

    /// Fingerprints of the files at or below the Vault-relative `scope`
    /// (a file or a folder; `""` is the whole Vault), outside `_brain/`.
    /// A `scope` that does not exist has no files.
    public static func capture(of vault: Vault, under scope: String) throws(VaultSnapshotError) -> VaultFileSnapshot {
        guard !isInBrainFolder(scope) else { return VaultFileSnapshot() }
        let root = vault.rootURL.resolvingSymlinksInPath()
        let rootPath = root.path + "/"
        let start = scope.isEmpty ? root : root.appending(path: scope)
        var fingerprints: [String: String] = [:]

        func relativePath(of url: URL) -> String? {
            let path = url.standardizedFileURL.path
            if path == root.path { return "" }
            guard path.hasPrefix(rootPath) else { return nil }
            return String(path.dropFirst(rootPath.count))
        }

        func isExcluded(_ relative: String) -> Bool {
            isInBrainFolder(relative) || relative.split(separator: "/").contains(where: { $0.hasPrefix(".") })
        }

        func failure(_ url: URL, _ error: any Error) -> VaultSnapshotError {
            VaultSnapshotError(relativePath: relativePath(of: url) ?? url.path, detail: error.localizedDescription)
        }

        func add(_ url: URL) throws(VaultSnapshotError) {
            guard let relative = relativePath(of: url), !isExcluded(relative) else { return }
            do {
                if let fingerprint = try fingerprint(of: url, relativePath: relative) {
                    fingerprints[relative] = fingerprint
                }
            } catch {
                // Deleted between listing and reading: gone, like any other deleted file.
                guard isConfirmedAbsent(url) else { throw failure(url, error) }
            }
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
        let values: URLResourceValues
        do {
            values = try start.resourceValues(forKeys: Set(keys))
        } catch {
            if isConfirmedAbsent(start) { return VaultFileSnapshot() }
            throw failure(start, error)
        }
        if values.isSymbolicLink == true { return VaultFileSnapshot() }
        if values.isDirectory != true {
            try add(start)
            return VaultFileSnapshot(fingerprints: fingerprints)
        }
        var enumerationError: VaultSnapshotError?
        guard let enumerator = FileManager.default.enumerator(
            at: start,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                if let relative = relativePath(of: url), isExcluded(relative) { return true }
                if isConfirmedAbsent(url) { return true }
                enumerationError = failure(url, error)
                return false
            }
        ) else {
            throw VaultSnapshotError(relativePath: scope, detail: "The folder could not be listed.")
        }
        for case let url as URL in enumerator {
            if let relative = relativePath(of: url), isInBrainFolder(relative) {
                enumerator.skipDescendants()
                continue
            }
            try add(url)
        }
        if let enumerationError { throw enumerationError }
        return VaultFileSnapshot(fingerprints: fingerprints)
    }

    public static func isInBrainFolder(_ relativePath: String) -> Bool {
        relativePath == NoteKind.brainFolder || relativePath.hasPrefix(NoteKind.brainFolder + "/")
    }

    /// `nil` for items left out of snapshots: symlinks and anything that is not a regular file.
    private static func fingerprint(of url: URL, relativePath: String) throws -> String? {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        if NoteKind.classify(relativePath: relativePath) != nil {
            let data = try Data(contentsOf: url)
            return "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let size = values.fileSize ?? 0
        let modified = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        return "stat:\(size):\(modified)"
    }

    /// Whether nothing exists at `url` (not even a dangling symlink), as opposed to
    /// something being there that cannot be read.
    private static func isConfirmedAbsent(_ url: URL) -> Bool {
        var status = stat()
        guard lstat(url.path, &status) != 0 else { return false }
        return errno == ENOENT || errno == ENOTDIR
    }
}

/// The notes a Brain Run processes: Daily Entries and Free Notes outside
/// `_brain/` that were added, modified or deleted since the last successful run.
public struct BrainRunChanges: Equatable, Sendable {
    /// Added or modified notes, sorted.
    public let changed: [String]
    /// Notes that no longer exist, sorted.
    public let deleted: [String]

    public init(changed: [String], deleted: [String]) {
        self.changed = changed
        self.deleted = deleted
    }

    /// `previous` is the snapshot taken at the start of the last successful
    /// Brain Run, or `nil` before the first one.
    public init(since previous: VaultFileSnapshot?, current: VaultFileSnapshot) {
        let old = previous?.fingerprints ?? [:]
        let new = current.fingerprints
        changed = new.keys.filter { Self.isNote($0) && old[$0] != new[$0] }.sorted()
        deleted = old.keys.filter { Self.isNote($0) && new[$0] == nil }.sorted()
    }

    public var isEmpty: Bool { changed.isEmpty && deleted.isEmpty }

    private static func isNote(_ relativePath: String) -> Bool {
        guard !VaultFileSnapshot.isInBrainFolder(relativePath) else { return false }
        switch NoteKind.classify(relativePath: relativePath) {
        case .dailyEntry, .freeNote: return true
        case .brainNote, nil: return false
        }
    }
}
