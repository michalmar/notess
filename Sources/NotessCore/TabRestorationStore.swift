import Foundation

/// Persists the ordered open tabs for the current Vault.
public struct TabRestorationStore {
    static let key = "tabRestoration"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func savedState(for vault: Vault) throws -> TabRestorationState? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        let stored = try JSONDecoder().decode(StoredState.self, from: data)
        guard stored.vaultPath == vault.rootURL.path(percentEncoded: false) else { return nil }
        return stored.state
    }

    public func remember(_ state: TabRestorationState, for vault: Vault) throws {
        let stored = StoredState(
            vaultPath: vault.rootURL.path(percentEncoded: false),
            state: state
        )
        defaults.set(try JSONEncoder().encode(stored), forKey: Self.key)
    }
}

private struct StoredState: Codable {
    let vaultPath: String
    let state: TabRestorationState
}
