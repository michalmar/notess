import Foundation
import Testing
@testable import NotessCore

@Suite("Remembering the Vault")
struct VaultLocationStoreTests {
    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "NotessTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("no Vault is known on first launch")
    func firstLaunch() throws {
        let store = VaultLocationStore(defaults: try isolatedDefaults())
        #expect(store.savedVault() == nil)
    }

    @Test("a chosen Vault is remembered across launches")
    func rememberedAcrossLaunches() throws {
        let defaults = try isolatedDefaults()
        let temp = try TemporaryVault()

        VaultLocationStore(defaults: defaults).remember(temp.vault)
        let nextLaunch = VaultLocationStore(defaults: defaults)

        #expect(nextLaunch.savedVault() == temp.vault)
    }

    @Test("a remembered Vault whose folder is gone is not returned")
    func missingFolderIsForgotten() throws {
        let defaults = try isolatedDefaults()
        let gone = Vault(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("NotessTests-missing-\(UUID().uuidString)", isDirectory: true))

        VaultLocationStore(defaults: defaults).remember(gone)

        #expect(VaultLocationStore(defaults: defaults).savedVault() == nil)
    }
}
