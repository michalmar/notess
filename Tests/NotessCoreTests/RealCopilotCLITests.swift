import Foundation
import Testing
@testable import NotessCore

/// Runs the real Copilot CLI (costs AI credits), so only with
/// `NOTESS_REAL_COPILOT=1 swift test --filter RealCopilotCLI`.
/// `NOTESS_COPILOT_MODEL` picks the model (default `claude-haiku-4.5`).
@Suite("Real Copilot CLI", .timeLimit(.minutes(2)), .enabled(if: ProcessInfo.processInfo.environment["NOTESS_REAL_COPILOT"] == "1"))
struct RealCopilotCLITests {
    private struct ModelRunner: BrainRunProcessRunner {
        let model: String
        func run(_ command: BrainRunCommand, output: @escaping @Sendable (String) -> Void) async throws -> Int32 {
            let command = BrainRunCommand(
                executableURL: command.executableURL,
                arguments: command.arguments + ["--model", model, "--disable-mcp-server", "workiq-mail"],
                currentDirectoryURL: command.currentDirectoryURL
            )
            return try await SystemProcessRunner().run(command, output: output)
        }
    }

    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func append(_ chunk: String) { lock.withLock { text += chunk } }
        var value: String { lock.withLock { text } }
    }

    @Test("the Agent writes Brain Notes with Citations and nothing outside _brain/")
    func endToEnd() async throws {
        let executable = try #require(CopilotCLILocator().detect())
        let temp = try TemporaryVault()
        try temp.write(
            "# 2026-03-14\n\n## Meeting\n\nMet Anna Nováková from Acme about the Atlas project.\n",
            to: "Journal/2026/03/2026-03-14.md"
        )
        let store = BrainRunStateStore(directoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("NotessRealCopilot-\(UUID().uuidString)", isDirectory: true))
        let model = ProcessInfo.processInfo.environment["NOTESS_COPILOT_MODEL"] ?? "claude-haiku-4.5"
        let log = Log()

        let outcome = await BrainRun(
            vault: temp.vault, executableURL: executable, store: store, runner: ModelRunner(model: model)
        ).run(log: log.append)

        print(log.value)
        #expect(outcome == .succeeded(processed: 1))
        let brain = temp.vault.rootURL.appending(path: "_brain")
        let notes = (FileManager.default.enumerator(at: brain, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "md" && $0.lastPathComponent != "AGENTS.md" }
        #expect(!notes.isEmpty)
        let texts = try notes.map { try String(contentsOf: $0, encoding: .utf8) }
        #expect(texts.contains { $0.contains("[[2026-03-14#Meeting]]") })
    }
}
