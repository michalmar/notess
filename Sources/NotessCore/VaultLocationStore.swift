import Foundation

/// Persists which folder is the Vault between launches. A plain path is
/// enough because the app is not sandboxed (ADR 0004).
public struct VaultLocationStore {
    static let key = "vaultPath"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The remembered Vault, or nil if none was chosen or its folder no longer exists.
    public func savedVault() -> Vault? {
        guard let path = defaults.string(forKey: Self.key) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return Vault(rootURL: URL(filePath: path, directoryHint: .isDirectory))
    }

    public func remember(_ vault: Vault) {
        defaults.set(vault.rootURL.path(percentEncoded: false), forKey: Self.key)
    }
}
