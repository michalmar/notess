import Foundation
@testable import NotessCore

/// A Vault in a fresh temporary directory, deleted on deinit.
final class TemporaryVault {
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
}
