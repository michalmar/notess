import Foundation
import Testing
@testable import NotessCore

@Suite("Restoring open tabs")
struct TabRestorationStoreTests {
    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "NotessTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("tab order and selection are restored only for their Vault")
    func remembersStateForVault() throws {
        let defaults = try isolatedDefaults()
        let vault = try TemporaryVault().vault
        let otherVault = try TemporaryVault().vault
        let state = TabRestorationState(
            relativePaths: ["Journal/2026/10/2026-10-14.md", "Notes/plan.md"],
            activeRelativePath: "Notes/plan.md"
        )

        try TabRestorationStore(defaults: defaults).remember(state, for: vault)
        let nextLaunch = TabRestorationStore(defaults: defaults)

        #expect(try nextLaunch.savedState(for: vault) == state)
        #expect(try nextLaunch.savedState(for: otherVault) == nil)
    }
}
