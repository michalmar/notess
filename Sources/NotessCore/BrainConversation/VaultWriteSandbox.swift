import Darwin
import Foundation

/// Why the Vault write sandbox cannot protect the Vault. A Brain Conversation refuses
/// to start rather than run unprotected.
public enum VaultWriteSandboxError: Error, Equatable, Sendable {
    /// The Vault's real path could not be resolved.
    case vaultUnresolvable(String)
    /// `sandbox-exec` is missing or does not run.
    case unavailable(String)
    /// A write into the Vault succeeded under the sandbox.
    case ineffective
    /// Vault files that also have hard links outside the Vault. Path rules cannot stop
    /// writes through those links, so the Vault would not be read-only.
    case outsideHardLinks([String])
}

/// Runs a command tree under macOS `sandbox-exec` with an allow-default policy that
/// denies every file write under the Vault's resolved real path.
///
/// The kernel resolves symlinks, letter case and Unicode normalization before checking
/// the path, and a sandboxed process cannot create a hard link to a Vault file. A hard
/// link that already exists outside the Vault is a different path the rule cannot see,
/// so `verify()` refuses such a Vault. Apple Events are denied too, so the Agent cannot
/// ask an unsandboxed app to write for it. Everything else, including reads and writes
/// outside the Vault and network access, stays allowed: the Vault is read-only, the
/// process is not side-effect free.
public struct VaultWriteSandbox: Sendable {
    public static let defaultExecutableURL = URL(filePath: "/usr/bin/sandbox-exec")

    public let vaultRealPath: String
    public let sandboxExecutableURL: URL

    public init(vault: Vault, sandboxExecutableURL: URL = Self.defaultExecutableURL) throws(VaultWriteSandboxError) {
        guard let resolved = realpath(vault.rootURL.path(percentEncoded: false), nil) else {
            throw .vaultUnresolvable(String(cString: strerror(errno)))
        }
        defer { free(resolved) }
        let path = String(cString: resolved)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw .vaultUnresolvable("\(path) není složka")
        }
        vaultRealPath = path
        self.sandboxExecutableURL = sandboxExecutableURL
    }

    /// The Seatbelt profile; the path is a string literal, so quotes and backslashes are escaped.
    public var profile: String {
        let escaped = vaultRealPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "(version 1)(allow default)(deny file-write* (subpath \"\(escaped)\"))(deny appleevent-send)"
    }

    /// The command line that runs `executable` with `arguments` inside the sandbox.
    public func wrap(_ executable: URL, arguments: [String]) -> (executable: URL, arguments: [String]) {
        (sandboxExecutableURL, ["-p", profile, executable.path(percentEncoded: false)] + arguments)
    }

    /// Proves the protection works for this Vault before anything runs under it:
    /// `sandbox-exec` runs a harmless command, refuses a new file in the Vault, and
    /// no Vault file has a hard link outside the Vault.
    public func verify() throws(VaultWriteSandboxError) {
        let sandboxPath = sandboxExecutableURL.path(percentEncoded: false)
        guard FileManager.default.isExecutableFile(atPath: sandboxPath) else {
            throw .unavailable("\(sandboxPath) chybí nebo není spustitelný")
        }
        let control = run(["/usr/bin/true"])
        guard control == 0 else {
            throw .unavailable("sandbox-exec skončil s kódem \(control.map(String.init) ?? "–")")
        }
        let probe = URL(filePath: vaultRealPath, directoryHint: .isDirectory)
            .appending(path: ".notess-sandbox-probe-\(UUID().uuidString)", directoryHint: .notDirectory)
        let probePath = probe.path(percentEncoded: false)
        let status = run(["/usr/bin/touch", probePath])
        if FileManager.default.fileExists(atPath: probePath) || status == 0 {
            try? FileManager.default.removeItem(at: probe)
            throw .ineffective
        }
        let linked = try outsideHardLinks()
        guard linked.isEmpty else { throw .outsideHardLinks(linked) }
    }

    /// Vault-relative paths of regular files with more hard links than the Vault holds.
    public func outsideHardLinks() throws(VaultWriteSandboxError) -> [String] {
        struct Inode: Hashable {
            let device: dev_t
            let number: ino_t
        }
        var links: [Inode: (found: Int, total: Int, path: String)] = [:]
        let root = URL(filePath: vaultRealPath, directoryHint: .isDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in true }
        ) else {
            throw .vaultUnresolvable("Vault nelze projít")
        }
        let prefix = vaultRealPath.hasSuffix("/") ? vaultRealPath : vaultRealPath + "/"
        for case let url as URL in enumerator {
            let path = url.path(percentEncoded: false)
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink > 1 else { continue }
            let key = Inode(device: info.st_dev, number: info.st_ino)
            let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
            let entry = links[key] ?? (0, Int(info.st_nlink), relative)
            links[key] = (entry.found + 1, entry.total, entry.path)
        }
        return links.values.filter { $0.found < $0.total }.map(\.path).sorted()
    }

    /// Runs a command inside the sandbox with no input or output; `nil` if it could not start.
    private func run(_ command: [String]) -> Int32? {
        let wrapped = wrap(URL(filePath: command[0]), arguments: Array(command.dropFirst()))
        let process = Process()
        process.executableURL = wrapped.executable
        process.arguments = wrapped.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
