import Foundation
import Testing
@testable import NotessCore

/// Runs a real shell under the real `sandbox-exec`: a fake sandbox proves nothing.
@Suite("Vault write sandbox")
struct VaultWriteSandboxTests {
    /// A Vault and a sibling folder outside it, under a parent with an awkward name.
    private final class Fixture {
        let base: URL
        let vault: Vault
        let outside: URL

        init(vaultName: String = "Vault") throws {
            base = FileManager.default.temporaryDirectory
                .appending(path: "NotessSandbox \"q\" \\ \(UUID().uuidString)", directoryHint: .isDirectory)
            let root = base.appending(path: vaultName, directoryHint: .isDirectory)
            outside = base.appending(path: "outside", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root.appending(path: "_brain"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            vault = Vault(rootURL: root)
            try write("original\n", to: "Journal.md")
        }

        deinit {
            try? FileManager.default.removeItem(at: base)
        }

        var rootPath: String { vault.rootURL.path(percentEncoded: false) }
        var outsidePath: String { outside.path(percentEncoded: false) }

        func write(_ text: String, to relativePath: String) throws {
            try text.write(to: vault.rootURL.appending(path: relativePath), atomically: false, encoding: .utf8)
        }

        func read(_ relativePath: String) throws -> String {
            try String(contentsOf: vault.rootURL.appending(path: relativePath), encoding: .utf8)
        }

        /// Runs `script` with `/bin/sh` inside the sandbox; returns the exit status and stdout.
        func runSandboxed(_ script: String, sandbox: VaultWriteSandbox? = nil) throws -> (status: Int32, output: String) {
            let sandbox = try sandbox ?? VaultWriteSandbox(vault: vault)
            let wrapped = sandbox.wrap(URL(filePath: "/bin/sh"), arguments: ["-c", script])
            let process = Process()
            process.executableURL = wrapped.executable
            process.arguments = wrapped.arguments
            process.currentDirectoryURL = vault.rootURL
            process.environment = ["VAULT": rootPath, "OUTSIDE": outsidePath, "PATH": "/usr/bin:/bin"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
    }

    @Test("direct writes, creates, renames and deletes inside the Vault fail")
    func directWrites() throws {
        let fixture = try Fixture()

        #expect(try fixture.runSandboxed(#"echo changed >> "$VAULT/Journal.md""#).status != 0)
        #expect(try fixture.runSandboxed(#"echo new > "$VAULT/_brain/New.md""#).status != 0)
        #expect(try fixture.runSandboxed(#"mkdir "$VAULT/Folder""#).status != 0)
        #expect(try fixture.runSandboxed(#"mv "$VAULT/Journal.md" "$VAULT/Moved.md""#).status != 0)
        #expect(try fixture.runSandboxed(#"rm "$VAULT/Journal.md""#).status != 0)
        #expect(try fixture.runSandboxed(#"mv "$VAULT/Journal.md" "$OUTSIDE/Taken.md""#).status != 0)

        #expect(try fixture.read("Journal.md") == "original\n")
        let entries = try FileManager.default.contentsOfDirectory(atPath: fixture.rootPath).sorted()
        #expect(entries == ["Journal.md", "_brain"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.outsidePath).isEmpty)
    }

    @Test("writes through symlinks inside and outside the Vault fail")
    func symlinkWrites() throws {
        let fixture = try Fixture()
        let target = fixture.vault.rootURL.appending(path: "Journal.md")
        try FileManager.default.createSymbolicLink(
            at: fixture.vault.rootURL.appending(path: "_brain/Alias.md"), withDestinationURL: target
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.outside.appending(path: "Alias.md"), withDestinationURL: target
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.outside.appending(path: "VaultLink"), withDestinationURL: fixture.vault.rootURL
        )

        #expect(try fixture.runSandboxed(#"echo changed >> "$VAULT/_brain/Alias.md""#).status != 0)
        #expect(try fixture.runSandboxed(#"echo changed >> "$OUTSIDE/Alias.md""#).status != 0)
        #expect(try fixture.runSandboxed(#"echo changed >> "$OUTSIDE/VaultLink/Journal.md""#).status != 0)
        #expect(try fixture.runSandboxed(#"echo new > "$OUTSIDE/VaultLink/New.md""#).status != 0)

        #expect(try fixture.read("Journal.md") == "original\n")
        #expect(!FileManager.default.fileExists(atPath: fixture.rootPath + "/New.md"))
    }

    @Test("writes through hard links inside the Vault fail and new hard links cannot be made")
    func hardLinkWrites() throws {
        let fixture = try Fixture()
        try FileManager.default.linkItem(
            at: fixture.vault.rootURL.appending(path: "Journal.md"),
            to: fixture.vault.rootURL.appending(path: "_brain/Linked.md")
        )

        #expect(try fixture.runSandboxed(#"echo changed >> "$VAULT/_brain/Linked.md""#).status != 0)
        #expect(try fixture.runSandboxed(#"ln "$VAULT/Journal.md" "$OUTSIDE/Linked.md""#).status != 0)
        #expect(try fixture.runSandboxed(#"ln -f "$VAULT/_brain/Linked.md" "$OUTSIDE/Linked.md""#).status != 0)

        #expect(!FileManager.default.fileExists(atPath: fixture.outsidePath + "/Linked.md"))
        #expect(try fixture.read("Journal.md") == "original\n")
        #expect(try fixture.read("_brain/Linked.md") == "original\n")
        #expect(try VaultWriteSandbox(vault: fixture.vault).outsideHardLinks().isEmpty)
    }

    @Test("a hard link that already exists outside the Vault is refused before anything runs")
    func outsideHardLinkIsRefused() throws {
        let fixture = try Fixture()
        try FileManager.default.linkItem(
            at: fixture.vault.rootURL.appending(path: "Journal.md"),
            to: fixture.outside.appending(path: "Linked.md")
        )
        let sandbox = try VaultWriteSandbox(vault: fixture.vault)

        #expect(throws: VaultWriteSandboxError.outsideHardLinks(["Journal.md"])) { try sandbox.verify() }
    }

    @Test("reads in the Vault and writes outside it succeed")
    func readsAndOutsideWrites() throws {
        let fixture = try Fixture()

        let read = try fixture.runSandboxed(#"cat "$VAULT/Journal.md" && ls "$VAULT""#)
        #expect(read.status == 0)
        #expect(read.output.contains("original"))
        #expect(read.output.contains("_brain"))
        let tempFile = "/tmp/notess-sandbox-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tempFile) }
        let outside = try fixture.runSandboxed(#"echo free > "$OUTSIDE/Free.md" && echo tmp > "\#(tempFile)""#)
        #expect(outside.status == 0)
        #expect(try String(contentsOf: fixture.outside.appending(path: "Free.md"), encoding: .utf8) == "free\n")
        #expect(FileManager.default.fileExists(atPath: tempFile))
    }

    @Test("a Vault named with diacritics, quotes and spaces is protected and verifies cleanly")
    func awkwardVaultName() throws {
        let fixture = try Fixture(vaultName: "Poznámky \"Ž\" (2026)")
        let sandbox = try VaultWriteSandbox(vault: fixture.vault)

        try sandbox.verify()
        #expect(try fixture.runSandboxed(#"echo changed >> "$VAULT/Journal.md""#).status != 0)
        #expect(try fixture.read("Journal.md") == "original\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.rootPath).sorted() == ["Journal.md", "_brain"])
    }

    @Test("verification fails closed when sandbox-exec is missing")
    func missingSandboxFailsClosed() throws {
        let fixture = try Fixture()
        let sandbox = try VaultWriteSandbox(
            vault: fixture.vault, sandboxExecutableURL: URL(filePath: "/nonexistent/sandbox-exec")
        )

        #expect {
            try sandbox.verify()
        } throws: { error in
            if case .unavailable = error as? VaultWriteSandboxError { return true }
            return false
        }
    }

    @Test("verification fails closed when the sandbox does not block Vault writes")
    func ineffectiveSandboxFailsClosed() throws {
        let fixture = try Fixture()
        let passThrough = fixture.outside.appending(path: "fake-sandbox-exec")
        // Drops "-p <profile>" and runs the command unprotected.
        try "#!/bin/sh\nshift 2\nexec \"$@\"\n".write(to: passThrough, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: passThrough.path)
        let sandbox = try VaultWriteSandbox(vault: fixture.vault, sandboxExecutableURL: passThrough)

        #expect(throws: VaultWriteSandboxError.ineffective) { try sandbox.verify() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.rootPath).sorted() == ["Journal.md", "_brain"])
    }

    @Test("verification leaves the Vault unchanged")
    func verificationLeavesNoTrace() throws {
        let fixture = try Fixture()
        try VaultWriteSandbox(vault: fixture.vault).verify()
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.rootPath).sorted() == ["Journal.md", "_brain"])
    }
}
