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

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: () -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func processCommand(_ processID: Int32) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/bin/ps")
        process.arguments = ["-o", "comm=", "-p", String(processID)]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    @Test("launches the command in a process group distinct from Notess")
    func isolatedProcessGroup() async throws {
        let collected = Collected()
        let status = try await SystemProcessRunner().run(
            shell("printf '%s ' \"$$\"; ps -o pgid= -p \"$$\""),
            output: collected.append
        )
        let identifiers = collected.value.split(whereSeparator: \.isWhitespace).compactMap {
            Int32(String($0))
        }

        #expect(status == 0)
        #expect(identifiers.count == 2)
        #expect(identifiers.first == identifiers.last)
        #expect(identifiers.first != getpgrp())
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

    @Test("a task cancelled before launch does not start a process")
    func cancellationBeforeLaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "NotessSystemProcessRunner-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let command = BrainRunCommand(
            executableURL: URL(filePath: "/bin/sh"),
            arguments: ["-c", "touch launched"],
            currentDirectoryURL: directory
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SystemProcessRunner().run(command, output: { _ in })
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "launched").path))
    }

    @Test("cancellation stops a resistant child after its parent exits")
    func cancellationStopsDescendantsAfterParentExit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "NotessSystemProcessRunner-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let childScript = directory.appending(path: "child.sh")
        try """
        trap '' TERM
        touch child-ready
        while :; do
          printf x >> child-writes
          sleep 0.05
        done
        """.write(to: childScript, atomically: true, encoding: .utf8)

        let command = BrainRunCommand(
            executableURL: URL(filePath: "/bin/sh"),
            arguments: [
                "-c",
                """
                /bin/sh child.sh &
                child=$!
                echo "$child" > child.pid
                echo $$ > parent.pid
                exec /bin/sleep 30
                """,
            ],
            currentDirectoryURL: directory
        )
        let task = Task {
            try await SystemProcessRunner(terminationGracePeriod: 0.1).run(command, output: { _ in })
        }

        do {
            let ready = try await waitUntil {
                FileManager.default.fileExists(atPath: directory.appending(path: "child-ready").path)
                    && FileManager.default.fileExists(atPath: directory.appending(path: "parent.pid").path)
            }
            #expect(ready)
            let childPID = try #require(
                Int32(String(contentsOf: directory.appending(path: "child.pid"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            )
            defer { kill(childPID, SIGKILL) }
            let parentPID = try #require(
                Int32(String(contentsOf: directory.appending(path: "parent.pid"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            )
            let parentIsReady = try await waitUntil {
                processCommand(parentPID)?.hasSuffix("/sleep") == true
            }
            #expect(parentIsReady)

            task.cancel()
            task.cancel()
            let status = try await task.value

            #expect(status == SIGTERM)

            let exited = try await waitUntil {
                kill(childPID, 0) == -1 && errno == ESRCH
            }
            #expect(exited)

            let writesURL = directory.appending(path: "child-writes")
            let writesAfterCancellation = try Data(contentsOf: writesURL)
            try await Task.sleep(for: .milliseconds(200))
            #expect(try Data(contentsOf: writesURL) == writesAfterCancellation)
        } catch {
            task.cancel()
            _ = try? await task.value
            throw error
        }
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
