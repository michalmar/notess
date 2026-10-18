import Foundation
@testable import NotessCore

/// A Vault in a fresh temporary directory, deleted on deinit.
final class TemporaryVault: Sendable {
    let vault: Vault

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vault = Vault(rootURL: root)
    }

    deinit {
        try? FileManager.default.removeItem(at: vault.rootURL)
    }

    func fileExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: vault.rootURL.appendingPathComponent(relativePath).path)
    }

    func read(_ relativePath: String) throws -> String {
        try String(contentsOf: vault.rootURL.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func write(_ text: String, to relativePath: String) throws {
        let url = vault.rootURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Takes all permissions from a file or folder; `restore()` gives them back
    /// (do so before the Vault is deleted).
    func makeUnreadable(_ relativePath: String) throws -> UnreadableItem {
        let path = vault.rootURL.appendingPathComponent(relativePath).path
        let original = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int ?? 0o755
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        return UnreadableItem(owner: self, path: path, permissions: original)
    }
}

struct UnreadableItem: Sendable {
    /// Keeps the Vault alive until the permissions are restored.
    let owner: TemporaryVault
    let path: String
    let permissions: Int

    func restore() {
        try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
    }
}
