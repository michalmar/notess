import Darwin
import Foundation

/// Locates the Copilot CLI without assuming the application's inherited PATH
/// matches the user's login shell.
public struct CopilotCLILocator: Sendable {
    private let fileExists: @Sendable (URL) -> Bool
    private let loginShellPath: @Sendable () -> [URL]

    public init() {
        self.fileExists = { FileManager.default.isExecutableFile(atPath: $0.path) }
        self.loginShellPath = Self.loginShellDirectories
    }

    public init(
        fileExists: @escaping @Sendable (URL) -> Bool,
        loginShellPath: @escaping @Sendable () -> [URL]
    ) {
        self.fileExists = fileExists
        self.loginShellPath = loginShellPath
    }

    public func detect() -> URL? {
        let candidates = Self.standardLocations + loginShellPath().map {
            $0.appendingPathComponent("copilot", isDirectory: false)
        }
        return candidates.first(where: fileExists)
    }

    private static var standardLocations: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(filePath: "/opt/homebrew/bin/copilot"),
            URL(filePath: "/usr/local/bin/copilot"),
            home.appendingPathComponent(".local/bin/copilot"),
            home.appendingPathComponent(".npm-global/bin/copilot"),
            home.appendingPathComponent("bin/copilot"),
        ]
    }

    private static func loginShellDirectories() -> [URL] {
        guard let shell = loginShell(), FileManager.default.isExecutableFile(atPath: shell) else {
            return []
        }

        let process = Process()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Notess-login-shell-path-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: outputURL) else { return [] }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        process.executableURL = URL(filePath: shell)
        process.arguments = ["-ilc", "printf '__NOTESS_PATH__%s__NOTESS_END__' \"$PATH\""]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            let completed = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in completed.signal() }
            try process.run()
            guard completed.wait(timeout: .now() + 2) == .success else {
                process.terminate()
                return []
            }
            guard process.terminationStatus == 0,
                  let output = try? String(contentsOf: outputURL, encoding: .utf8),
                  let start = output.range(of: "__NOTESS_PATH__"),
                  let end = output[start.upperBound...].range(of: "__NOTESS_END__")
            else {
                return []
            }
            let path = String(output[start.upperBound..<end.lowerBound])
            return path.split(separator: ":").map { URL(filePath: String($0), directoryHint: .isDirectory) }
        } catch {
            return []
        }
    }

    private static func loginShell() -> String? {
        guard let entry = getpwuid(getuid()), entry.pointee.pw_shell != nil else { return nil }
        return String(cString: entry.pointee.pw_shell)
    }
}
