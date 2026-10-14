import Foundation
import Testing
@testable import NotessCore

@Suite("Brain Run: last successful run")
struct BrainRunStateStoreTests {
    private func makeStore() -> (BrainRunStateStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotessBrainRunState-\(UUID().uuidString)", isDirectory: true)
        return (BrainRunStateStore(directoryURL: directory), directory)
    }

    @Test("there is no last successful run before the first one")
    func noRunYet() throws {
        let temp = try TemporaryVault()
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try store.lastSuccessfulRun(for: temp.vault) == nil)
    }

    @Test("remembers the last successful run per Vault")
    func remembersPerVault() throws {
        let first = try TemporaryVault()
        let second = try TemporaryVault()
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = BrainRunRecord(
            completedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            snapshot: VaultFileSnapshot(fingerprints: ["Plan.md": "sha256:ab"])
        )

        try store.rememberSuccessfulRun(record, for: first.vault)

        #expect(try store.lastSuccessfulRun(for: first.vault) == record)
        #expect(try BrainRunStateStore(directoryURL: directory).lastSuccessfulRun(for: first.vault) == record)
        #expect(try store.lastSuccessfulRun(for: second.vault) == nil)
    }
}
