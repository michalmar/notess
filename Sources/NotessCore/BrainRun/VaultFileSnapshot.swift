import CryptoKit
import Foundation

/// What every file outside `_brain/` looked like at one moment: the basis for
/// choosing the notes a Brain Run processes and for noticing that something
/// other than the user changed the user's files during a run.
///
/// Notes are fingerprinted by content (a rewrite with the same text is no
/// change); other files, such as attachments, by size and modification date.
/// Hidden items (`.git`, `.DS_Store`) and symlinks are left out.
public struct VaultFileSnapshot: Codable, Equatable, Sendable {
    /// Vault-relative path → fingerprint.
    public var fingerprints: [String: String]

    public init(fingerprints: [String: String] = [:]) {
        self.fingerprints = fingerprints
    }

    public static func capture(of vault: Vault) -> VaultFileSnapshot {
        capture(of: vault, under: "")
    }

    /// Fingerprints of the files at or below the Vault-relative `scope`
    /// (a file or a folder; `""` is the whole Vault), outside `_brain/`.
    public static func capture(of vault: Vault, under scope: String) -> VaultFileSnapshot {
        guard !isInBrainFolder(scope) else { return VaultFileSnapshot() }
        let root = vault.rootURL.resolvingSymlinksInPath()
        let rootPath = root.path + "/"
        let start = scope.isEmpty ? root : root.appending(path: scope)
        var fingerprints: [String: String] = [:]

        func add(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath) else { return }
            let relative = String(path.dropFirst(rootPath.count))
            guard !isInBrainFolder(relative),
                  !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }),
                  let fingerprint = fingerprint(of: url, relativePath: relative) else { return }
            fingerprints[relative] = fingerprint
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
        let values = try? start.resourceValues(forKeys: Set(keys))
        if values?.isSymbolicLink == true { return VaultFileSnapshot() }
        if values?.isDirectory != true {
            add(start)
            return VaultFileSnapshot(fingerprints: fingerprints)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: start,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return VaultFileSnapshot() }
        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            if path.hasPrefix(rootPath), isInBrainFolder(String(path.dropFirst(rootPath.count))) {
                enumerator.skipDescendants()
                continue
            }
            add(url)
        }
        return VaultFileSnapshot(fingerprints: fingerprints)
    }

    public static func isInBrainFolder(_ relativePath: String) -> Bool {
        relativePath == NoteKind.brainFolder || relativePath.hasPrefix(NoteKind.brainFolder + "/")
    }

    private static func fingerprint(of url: URL, relativePath: String) -> String? {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        ), values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        if NoteKind.classify(relativePath: relativePath) != nil {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let size = values.fileSize ?? 0
        let modified = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        return "stat:\(size):\(modified)"
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
