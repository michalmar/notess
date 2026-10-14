import Foundation

/// Runs a `BrainRunCommand` as a child process with no input, merging stdout and
/// stderr. Cancelling the calling task sends SIGTERM, then SIGKILL after
/// `terminationGracePeriod` if the process is still alive.
public struct SystemProcessRunner: BrainRunProcessRunner {
    public var terminationGracePeriod: TimeInterval

    public init(terminationGracePeriod: TimeInterval = 5) {
        self.terminationGracePeriod = terminationGracePeriod
    }

    public func run(_ command: BrainRunCommand, output: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.currentDirectoryURL = command.currentDirectoryURL
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let control = ProcessControl(process: process, gracePeriod: terminationGracePeriod)
        let decoder = UTF8StreamDecoder()
        let outputClosed = DispatchGroup()
        outputClosed.enter()
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                let rest = decoder.finish()
                if !rest.isEmpty { output(rest) }
                outputClosed.leave()
            } else {
                let text = decoder.decode(data)
                if !text.isEmpty { output(text) }
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { process in
                    // Let the output drain; a lingering grandchild may hold the pipe open.
                    if outputClosed.wait(timeout: .now() + 2) == .timedOut {
                        reader.readabilityHandler = nil
                    }
                    continuation.resume(returning: process.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    reader.readabilityHandler = nil
                    try? pipe.fileHandleForWriting.close()
                    continuation.resume(throwing: error)
                    return
                }
                // The parent's copy of the write end would keep the pipe from reaching EOF.
                try? pipe.fileHandleForWriting.close()
                control.didLaunch()
            }
        } onCancel: {
            control.cancel()
        }
    }
}

/// Makes "cancel" safe whether it arrives before, during or after launch.
private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private let gracePeriod: TimeInterval
    private var launched = false
    private var cancelled = false

    init(process: Process, gracePeriod: TimeInterval) {
        self.process = process
        self.gracePeriod = gracePeriod
    }

    func didLaunch() {
        let stop = lock.withLock {
            launched = true
            return cancelled
        }
        if stop { terminate() }
    }

    func cancel() {
        let stop = lock.withLock {
            cancelled = true
            return launched
        }
        if stop { terminate() }
    }

    private func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + gracePeriod) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// Decodes UTF-8 arriving in arbitrary chunks without splitting characters.
final class UTF8StreamDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func decode(_ data: Data) -> String {
        lock.withLock {
            pending.append(data)
            let cut = Self.completePrefixLength(of: pending)
            let text = String(decoding: pending.prefix(cut), as: UTF8.self)
            pending = Data(pending.dropFirst(cut))
            return text
        }
    }

    func finish() -> String {
        lock.withLock {
            defer { pending = Data() }
            return String(decoding: pending, as: UTF8.self)
        }
    }

    /// Length of `data` without a trailing, still incomplete multi-byte sequence.
    static func completePrefixLength(of data: Data) -> Int {
        let bytes = [UInt8](data.suffix(4))
        let base = data.count - bytes.count
        var index = bytes.count - 1
        while index >= 0, bytes[index] & 0b1100_0000 == 0b1000_0000, bytes.count - index < 4 {
            index -= 1
        }
        guard index >= 0 else { return data.count }
        let lead = bytes[index]
        let length = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
        return bytes.count - index < length ? base + index : data.count
    }
}
