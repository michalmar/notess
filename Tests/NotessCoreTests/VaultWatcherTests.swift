import Foundation
import Synchronization
import Testing
@testable import NotessCore

@Suite("Watching the Vault for outside changes")
struct VaultWatcherTests {
    @Test("an added file is reported by its Vault-relative path")
    func reportsAddedFile() async throws {
        let temp = try TemporaryVault()
        let changes = try await collectChanges(in: temp, until: { $0.contains("Notes/New.md") }) {
            try temp.write("hi\n", to: "Notes/New.md")
        }

        #expect(changes.contains("Notes/New.md"))
    }

    @Test("a deleted file is reported")
    func reportsDeletedFile() async throws {
        let temp = try TemporaryVault()
        try temp.write("hi\n", to: "Gone.md")
        let changes = try await collectChanges(in: temp, until: { $0.contains("Gone.md") }) {
            try FileManager.default.removeItem(at: temp.vault.rootURL.appending(path: "Gone.md"))
        }

        #expect(changes.contains("Gone.md"))
    }

    @Test("changes inside hidden folders such as .git are not reported")
    func ignoresHiddenItems() async throws {
        let temp = try TemporaryVault()
        let changes = try await collectChanges(in: temp, until: { $0.contains("Visible.md") }) {
            try temp.write("x", to: ".git/index")
            try temp.write("x", to: ".DS_Store")
            try temp.write("hi\n", to: "Visible.md")
        }

        #expect(changes.allSatisfy { !$0.hasPrefix(".") })
    }

    @Test("a stopped watcher reports nothing")
    func stoppedWatcherIsSilent() async throws {
        let temp = try TemporaryVault()
        let received = Mutex(false)
        let watcher = VaultWatcher(rootURL: temp.vault.rootURL, latency: 0.05, queue: DispatchQueue(label: "test")) { _ in
            received.withLock { $0 = true }
        }
        try watcher.start()
        watcher.stop()

        try temp.write("hi\n", to: "Late.md")
        try await Task.sleep(for: .milliseconds(500))

        #expect(received.withLock { $0 } == false)
    }

    @Test("event paths map to Vault-relative paths, skipping hidden items and outsiders")
    func relativePaths() {
        let root = "/Users/me/Vault"
        #expect(VaultChange.relativePath(ofEventPath: "/Users/me/Vault/Journal/2026/10/2026-10-14.md", inRoot: root)
            == "Journal/2026/10/2026-10-14.md")
        #expect(VaultChange.relativePath(ofEventPath: "/Users/me/Vault", inRoot: root) == "")
        #expect(VaultChange.relativePath(ofEventPath: "/Users/me/Vault/.git/HEAD", inRoot: root) == nil)
        #expect(VaultChange.relativePath(ofEventPath: "/Users/me/Vault/Notes/.Idea.md.swp", inRoot: root) == nil)
        #expect(VaultChange.relativePath(ofEventPath: "/Users/me/Vault2/a.md", inRoot: root) == nil)
    }

    /// Starts a watcher, runs `action` and gathers reported paths until `done` holds.
    private func collectChanges(
        in temp: TemporaryVault,
        until done: @escaping @Sendable (Set<String>) -> Bool,
        action: () throws -> Void
    ) async throws -> Set<String> {
        let collected = Mutex(Set<String>())
        let watcher = VaultWatcher(rootURL: temp.vault.rootURL, latency: 0.05, queue: DispatchQueue(label: "test")) { change in
            collected.withLock { $0.formUnion(change.relativePaths) }
        }
        try watcher.start()
        defer { watcher.stop() }
        // FSEvents may miss changes made right after the stream starts.
        try await Task.sleep(for: .milliseconds(200))
        try action()

        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            let snapshot = collected.withLock { $0 }
            if done(snapshot) { return snapshot }
            try await Task.sleep(for: .milliseconds(50))
        }
        return collected.withLock { $0 }
    }
}
