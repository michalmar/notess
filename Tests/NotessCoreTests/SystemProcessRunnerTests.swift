import Foundation
import Testing
@testable import NotessCore

@Suite("System process runner")
struct SystemProcessRunnerTests {
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func append(_ chunk: String) { lock.withLock { text += chunk } }
        var value: String { lock.withLock { text } }
    }

    private func shell(_ script: String) -> BrainRunCommand {
        BrainRunCommand(
            executableURL: URL(filePath: "/bin/sh"),
            arguments: ["-c", script],
            currentDirectoryURL: FileManager.default.temporaryDirectory
        )
    }

    @Test("streams stdout and stderr and returns the exit status")
    func outputAndStatus() async throws {
        let collected = Collected()
        let status = try await SystemProcessRunner().run(
            shell("echo out; echo chyba >&2; printf 'Žluťoučký kůň'; exit 3"),
            output: collected.append
        )

        #expect(status == 3)
        #expect(collected.value.contains("out\n"))
        #expect(collected.value.contains("chyba\n"))
        #expect(collected.value.contains("Žluťoučký kůň"))
    }

    @Test("cancelling the task terminates the process")
    func cancellation() async throws {
        let start = ContinuousClock.now
        let task = Task {
            try await SystemProcessRunner(terminationGracePeriod: 1).run(shell("sleep 30"), output: { _ in })
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        _ = try? await task.value

        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test("a missing executable throws")
    func missingExecutable() async {
        let command = BrainRunCommand(
            executableURL: URL(filePath: "/nonexistent/copilot"),
            arguments: [],
            currentDirectoryURL: FileManager.default.temporaryDirectory
        )
        await #expect(throws: (any Error).self) {
            try await SystemProcessRunner().run(command, output: { _ in })
        }
    }

    @Test("UTF-8 split across chunks is decoded whole")
    func splitUTF8() {
        let decoder = UTF8StreamDecoder()
        let bytes = Data("až".utf8)
        let first = decoder.decode(bytes.prefix(bytes.count - 1))
        let second = decoder.decode(bytes.suffix(1))
        #expect(first == "a")
        #expect(second == "ž")
        #expect(decoder.finish() == "")
    }
}
