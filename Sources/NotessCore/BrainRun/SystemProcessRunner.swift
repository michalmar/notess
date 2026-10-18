import Darwin
import Foundation

/// Runs a `BrainRunCommand` as a child process with no input, merging stdout and
/// stderr. Each command owns a separate process group. Cancelling the calling
/// task sends SIGTERM to that group, then SIGKILL after
/// `terminationGracePeriod` if any owned process is still alive.
public struct SystemProcessRunner: BrainRunProcessRunner {
    public var terminationGracePeriod: TimeInterval

    public init(terminationGracePeriod: TimeInterval = 5) {
        self.terminationGracePeriod = terminationGracePeriod
    }

    public func run(_ command: BrainRunCommand, output: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        try Task.checkCancellation()

        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"

        var descriptors = [Int32](repeating: -1, count: 2)
        let pipeResult = descriptors.withUnsafeMutableBufferPointer {
            Darwin.pipe($0.baseAddress!)
        }
        guard pipeResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        let readDescriptor = descriptors[0]
        let writeDescriptor = descriptors[1]
        guard fcntl(readDescriptor, F_SETFD, FD_CLOEXEC) != -1,
              fcntl(writeDescriptor, F_SETFD, FD_CLOEXEC) != -1
        else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno)!)
            Darwin.close(readDescriptor)
            Darwin.close(writeDescriptor)
            throw error
        }

        let control = ProcessGroupControl(gracePeriod: terminationGracePeriod)
        let decoder = UTF8StreamDecoder()
        let outputClosed = DispatchGroup()
        outputClosed.enter()
        let reader = FileHandle(fileDescriptor: readDescriptor, closeOnDealloc: true)
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
            let processID: pid_t
            do {
                processID = try Self.spawn(
                    command,
                    environment: environment,
                    readDescriptor: readDescriptor,
                    writeDescriptor: writeDescriptor
                )
            } catch {
                reader.readabilityHandler = nil
                try? reader.close()
                Darwin.close(writeDescriptor)
                throw error
            }
            Darwin.close(writeDescriptor)
            control.didLaunch(processGroupID: processID)

            let status = try await Self.wait(for: processID)

            // Let the output drain; a lingering grandchild may hold the pipe open.
            if await !Self.waitForOutputToClose(outputClosed) {
                reader.readabilityHandler = nil
            }
            await control.finish(isCancelled: Task.isCancelled)
            return status
        } onCancel: {
            control.cancel()
        }
    }

    private static func spawn(
        _ command: BrainRunCommand,
        environment: [String: String],
        readDescriptor: Int32,
        writeDescriptor: Int32
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        try check(posix_spawn_file_actions_addopen(
            &fileActions,
            STDIN_FILENO,
            "/dev/null",
            O_RDONLY,
            0
        ))
        try check(posix_spawn_file_actions_adddup2(&fileActions, writeDescriptor, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&fileActions, writeDescriptor, STDERR_FILENO))
        if readDescriptor > STDERR_FILENO {
            try check(posix_spawn_file_actions_addclose(&fileActions, readDescriptor))
        }
        if writeDescriptor > STDERR_FILENO {
            try check(posix_spawn_file_actions_addclose(&fileActions, writeDescriptor))
        }
        try check(posix_spawn_file_actions_addchdir_np(
            &fileActions,
            command.currentDirectoryURL.path
        ))

        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGTERM)
        try check(posix_spawnattr_setsigdefault(&attributes, &defaultSignals))
        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        try check(posix_spawnattr_setsigmask(&attributes, &signalMask))
        try check(posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        ))
        try check(posix_spawnattr_setpgroup(&attributes, 0))

        var arguments = try cStrings([command.executableURL.path] + command.arguments)
        defer { freeCStrings(arguments) }
        var environmentVariables = try cStrings(
            environment.map { "\($0.key)=\($0.value)" }
        )
        defer { freeCStrings(environmentVariables) }

        var processID: pid_t = 0
        let result = arguments.withUnsafeMutableBufferPointer { argumentBuffer in
            environmentVariables.withUnsafeMutableBufferPointer { environmentBuffer in
                posix_spawn(
                    &processID,
                    command.executableURL.path,
                    &fileActions,
                    &attributes,
                    argumentBuffer.baseAddress!,
                    environmentBuffer.baseAddress!
                )
            }
        }
        try check(result)
        return processID
    }

    private static func waitForOutputToClose(_ outputClosed: DispatchGroup) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: outputClosed.wait(timeout: .now() + 2) == .success)
            }
        }
    }

    private static func wait(for processID: pid_t) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                var waitStatus: Int32 = 0
                var result: pid_t
                repeat {
                    result = waitpid(processID, &waitStatus, 0)
                } while result == -1 && errno == EINTR

                guard result == processID else {
                    continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: errno)!))
                    return
                }
                if waitStatus & 0x7f == 0 {
                    continuation.resume(returning: (waitStatus >> 8) & 0xff)
                } else {
                    continuation.resume(returning: waitStatus & 0x7f)
                }
            }
        }
    }

    private static func cStrings(_ strings: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        for string in strings {
            guard let pointer = strdup(string) else {
                freeCStrings(pointers)
                throw POSIXError(.ENOMEM)
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
        return pointers
    }

    private static func freeCStrings(_ pointers: [UnsafeMutablePointer<CChar>?]) {
        for pointer in pointers {
            free(pointer)
        }
    }

    private static func check(_ result: Int32) throws {
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: result)!)
        }
    }
}

/// Makes "cancel" safe whether it arrives before, during or after launch.
private final class ProcessGroupControl: @unchecked Sendable {
    private let lock = NSLock()
    private let gracePeriod: TimeInterval
    private var processGroupID: pid_t?
    private var cancelled = false
    private var finished = false
    private var terminationTask: Task<Void, Never>?

    init(gracePeriod: TimeInterval) {
        self.gracePeriod = gracePeriod
    }

    func didLaunch(processGroupID: pid_t) {
        lock.withLock {
            self.processGroupID = processGroupID
            startTerminationIfNeeded()
        }
    }

    func cancel() {
        lock.withLock {
            guard !finished else { return }
            cancelled = true
            startTerminationIfNeeded()
        }
    }

    func finish(isCancelled: Bool) async {
        let task = lock.withLock {
            if isCancelled { cancelled = true }
            startTerminationIfNeeded()
            finished = true
            return terminationTask
        }
        await task?.value
    }

    private func startTerminationIfNeeded() {
        guard cancelled, terminationTask == nil, let processGroupID else { return }
        let gracePeriod = self.gracePeriod
        terminationTask = Task.detached {
            guard processGroupID > 1, processGroupID != getpgrp() else { return }
            kill(-processGroupID, SIGTERM)

            await Self.waitUntilGroupExits(processGroupID, timeout: gracePeriod)
            guard Self.groupExists(processGroupID) else { return }

            kill(-processGroupID, SIGKILL)
            await Self.waitUntilGroupExits(processGroupID, timeout: 2)
        }
    }

    private static func waitUntilGroupExits(_ processGroupID: pid_t, timeout: TimeInterval) async {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while groupExists(processGroupID), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func groupExists(_ processGroupID: pid_t) -> Bool {
        if kill(-processGroupID, 0) == 0 { return true }
        return errno != ESRCH
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
