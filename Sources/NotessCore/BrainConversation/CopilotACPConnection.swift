import Darwin
import Foundation

/// Copilot CLI in ACP mode (`copilot --acp`): newline-delimited JSON-RPC 2.0 over stdio,
/// the whole process tree wrapped in the Vault write sandbox and owning one process group.
///
/// All tools are allowed, built-in MCP servers are disabled, and any permission request
/// the Agent still makes is allowed and reported as `.permissionAllowed`. The Vault stays
/// read-only because of the sandbox, not because of instructions or CLI permissions.
public final class CopilotACPConnection: ACPConnection, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var executableURL: URL
        public var model: String?
        public var sandboxExecutableURL: URL
        /// How long `initialize` and `session/new` may take.
        public var startupTimeout: TimeInterval
        /// How long a cancelled prompt may take to end before the process group is terminated.
        public var cancelGracePeriod: TimeInterval
        /// How long the process group gets after SIGTERM before SIGKILL.
        public var terminationGracePeriod: TimeInterval
        /// Extra Copilot CLI arguments appended after the standard ones.
        public var additionalArguments: [String]

        public init(
            executableURL: URL,
            model: String? = nil,
            sandboxExecutableURL: URL = VaultWriteSandbox.defaultExecutableURL,
            startupTimeout: TimeInterval = 90,
            cancelGracePeriod: TimeInterval = 5,
            terminationGracePeriod: TimeInterval = 3,
            additionalArguments: [String] = []
        ) {
            self.executableURL = executableURL
            self.model = model
            self.sandboxExecutableURL = sandboxExecutableURL
            self.startupTimeout = startupTimeout
            self.cancelGracePeriod = cancelGracePeriod
            self.terminationGracePeriod = terminationGracePeriod
            self.additionalArguments = additionalArguments
        }
    }

    /// Copilot CLI arguments. The user's custom instructions are not loaded: the
    /// conversation's own instructions travel in its first prompt.
    public static func arguments(model: String?) -> [String] {
        var arguments = [
            "--acp",
            "--allow-all",
            "--no-ask-user",
            "--disable-builtin-mcps",
            "--no-custom-instructions",
            "--disable-client-telemetry",
            "--no-auto-update",
        ]
        if let model { arguments += ["--model", model] }
        return arguments
    }

    private typealias Reply = Result<JSONValue, BrainConversationError>

    private let vault: Vault
    private let configuration: Configuration
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "Notess.CopilotACPConnection.write")
    private let decoder = JSONDecoder()

    // Guarded by `lock`.
    private var processID: pid_t?
    private var inputDescriptor: Int32 = -1
    private var attachedSession: String?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<Reply, Never>] = [:]
    private var eventHandler: (@Sendable (ACPSessionEvent) -> Void)?
    private var activePrompt: Int?
    private var promptCounter = 0
    private var exitStatus: Int32?
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private var groupGone = false
    private var isClosed = false
    private var outputBuffer = Data()
    private var errorTail = Data()

    public init(vault: Vault, configuration: Configuration) {
        self.vault = vault
        self.configuration = configuration
    }

    deinit {
        // The leader is alive, so its group id cannot have been reused.
        if let processID, exitStatus == nil {
            kill(-processID, SIGKILL)
        }
    }

    // MARK: ACPConnection

    public var sessionID: String? {
        lock.withLock { attachedSession }
    }

    public func start(resuming savedSession: String?) async throws(BrainConversationError) {
        let vault = self.vault
        let sandboxURL = configuration.sandboxExecutableURL
        let verified = await Self.offCooperativePool { () -> Result<VaultWriteSandbox, VaultWriteSandboxError> in
            Result { () throws(VaultWriteSandboxError) in
                let sandbox = try VaultWriteSandbox(vault: vault, sandboxExecutableURL: sandboxURL)
                try sandbox.verify()
                return sandbox
            }
        }
        let sandbox: VaultWriteSandbox
        switch verified {
        case .success(let value): sandbox = value
        case .failure(let error): throw .sandbox(error)
        }
        if Task.isCancelled { throw .launch("Spuštění bylo zrušeno.") }

        try launch(under: sandbox)

        let timeout = configuration.startupTimeout
        let initialize = await withTaskCancellationHandler {
            await request("initialize", .object([
                "protocolVersion": .number(1),
                "clientCapabilities": .object([
                    "fs": .object(["readTextFile": .bool(false), "writeTextFile": .bool(false)]),
                    "terminal": .bool(false),
                ]),
            ]), timeout: timeout)
        } onCancel: {
            self.terminateGroup()
        }
        guard case .success(let info) = initialize else { throw initialize.failure! }
        guard info["protocolVersion"]?.intValue != nil else {
            throw .protocolViolation("Odpověď na initialize neobsahuje verzi protokolu.")
        }
        if savedSession != nil, info["agentCapabilities"]?["loadSession"] != .bool(true) {
            throw .sessionUnavailable("Tato verze Copilot CLI nepodporuje načtení uložené relace (session/load).")
        }

        if let savedSession {
            // Replayed history arrives before the answer and is dropped: no session is
            // attached yet, so `deliver` has nowhere to report it.
            let loaded = await withTaskCancellationHandler {
                await request("session/load", .object([
                    "sessionId": .string(savedSession),
                    "cwd": .string(sandbox.vaultRealPath),
                    "mcpServers": .array([]),
                ]), timeout: timeout)
            } onCancel: {
                self.terminateGroup()
            }
            if case .failure(let error) = loaded {
                if case .agent(let detail) = error { throw .sessionUnavailable(detail) }
                throw error
            }
            lock.withLock { attachedSession = savedSession }
            return
        }

        let session = await withTaskCancellationHandler {
            await request("session/new", .object([
                "cwd": .string(sandbox.vaultRealPath),
                "mcpServers": .array([]),
            ]), timeout: timeout)
        } onCancel: {
            self.terminateGroup()
        }
        guard case .success(let created) = session else { throw session.failure! }
        guard let id = created["sessionId"]?.stringValue else {
            throw .protocolViolation("Odpověď na session/new neobsahuje sessionId.")
        }
        lock.withLock { attachedSession = id }
    }

    public func prompt(
        _ blocks: [String],
        events: @escaping @Sendable (ACPSessionEvent) -> Void
    ) async throws(BrainConversationError) -> ACPStopReason {
        let started: (session: String, token: Int)? = lock.withLock {
            guard let sessionID = attachedSession, !isClosed, exitStatus == nil, activePrompt == nil else { return nil }
            promptCounter += 1
            activePrompt = promptCounter
            eventHandler = events
            return (sessionID, promptCounter)
        }
        guard let started else { throw .protocolViolation("Relace Agenta není otevřená.") }
        defer {
            lock.withLock {
                eventHandler = nil
                activePrompt = nil
            }
        }
        if Task.isCancelled { return .cancelled }

        let parameters: JSONValue = .object([
            "sessionId": .string(started.session),
            "prompt": .array(blocks.map { .object(["type": .string("text"), "text": .string($0)]) }),
        ])
        let reply = await withTaskCancellationHandler {
            await request("session/prompt", parameters, timeout: nil)
        } onCancel: {
            self.cancelPrompt(session: started.session, token: started.token)
        }
        switch reply {
        case .success(let result):
            guard let raw = result["stopReason"]?.stringValue else {
                throw .protocolViolation("Odpověď na session/prompt neobsahuje stopReason.")
            }
            return ACPStopReason(raw)
        case .failure(let error):
            if Task.isCancelled {
                await close()
                return .cancelled
            }
            throw error
        }
    }

    public func isOpen() async -> Bool {
        lock.withLock { attachedSession != nil && !isClosed && exitStatus == nil }
    }

    /// Runs to the end even when the calling task is cancelled (Stop, Vault change, quit).
    public func close() async {
        await Task.detached { await self.terminateAndWait() }.value
    }

    private func terminateAndWait() async {
        let processID: pid_t? = lock.withLock {
            isClosed = true
            attachedSession = nil
            return groupGone ? nil : self.processID
        }
        closeInput()
        guard let processID else { return }
        if groupExists(processID) {
            kill(-processID, SIGTERM)
            await waitUntilGroupExits(processID, timeout: configuration.terminationGracePeriod)
            if groupExists(processID) {
                kill(-processID, SIGKILL)
                await waitUntilGroupExits(processID, timeout: 5)
            }
        }
        await waitForLeaderExit()
        lock.withLock { groupGone = !groupExists(processID) || groupGone }
    }

    // MARK: Launch

    private func launch(under sandbox: VaultWriteSandbox) throws(BrainConversationError) {
        let wrapped = sandbox.wrap(configuration.executableURL, arguments: Self.arguments(model: configuration.model) + configuration.additionalArguments)
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"

        let input: (read: Int32, write: Int32)
        let output: (read: Int32, write: Int32)
        let errors: (read: Int32, write: Int32)
        do {
            input = try Self.makePipe()
            output = try Self.makePipe()
            errors = try Self.makePipe()
        } catch {
            throw .launch(error.localizedDescription)
        }
        _ = fcntl(input.write, F_SETNOSIGPIPE, 1)

        let processID: pid_t
        do {
            processID = try Self.spawn(
                wrapped.executable,
                arguments: wrapped.arguments,
                environment: environment,
                directory: sandbox.vaultRealPath,
                input: input.read,
                output: output.write,
                errors: errors.write,
                close: [input.write, output.read, errors.read]
            )
        } catch {
            for descriptor in [input.read, input.write, output.read, output.write, errors.read, errors.write] {
                Darwin.close(descriptor)
            }
            throw .launch(error.localizedDescription)
        }
        Darwin.close(input.read)
        Darwin.close(output.write)
        Darwin.close(errors.write)
        lock.withLock {
            self.processID = processID
            inputDescriptor = input.write
        }

        // Both streams are read to EOF so output written just before an exit is not lost.
        let streamsClosed = DispatchGroup()
        let outputHandle = FileHandle(fileDescriptor: output.read, closeOnDealloc: true)
        let errorHandle = FileHandle(fileDescriptor: errors.read, closeOnDealloc: true)
        for (handle, isOutput) in [(outputHandle, true), (errorHandle, false)] {
            streamsClosed.enter()
            handle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    streamsClosed.leave()
                } else if isOutput {
                    self?.receive(data)
                } else {
                    self?.receiveError(data)
                }
            }
        }

        // The handles live until the leader has exited and its streams are drained.
        DispatchQueue.global().async { [weak self] in
            var waitStatus: Int32 = 0
            var result: pid_t
            repeat {
                result = waitpid(processID, &waitStatus, 0)
            } while result == -1 && errno == EINTR
            let status: Int32 = waitStatus & 0x7f == 0 ? (waitStatus >> 8) & 0xff : 128 + (waitStatus & 0x7f)
            // A surviving child may hold the pipes open; do not wait for it forever.
            if streamsClosed.wait(timeout: .now() + 2) != .success {
                outputHandle.readabilityHandler = nil
                errorHandle.readabilityHandler = nil
            }
            self?.processDidExit(status: status)
            withExtendedLifetime((outputHandle, errorHandle)) {}
        }
    }

    private func processDidExit(status: Int32) {
        let (requests, waiters, detail): ([CheckedContinuation<Reply, Never>], [CheckedContinuation<Void, Never>], String) =
            lock.withLock {
                exitStatus = status
                attachedSession = nil
                defer {
                    pending = [:]
                    exitWaiters = []
                }
                return (Array(pending.values), exitWaiters, String(decoding: errorTail, as: UTF8.self))
            }
        closeInput()
        let error = Self.exitError(status: status, detail: detail)
        for request in requests { request.resume(returning: .failure(error)) }
        for waiter in waiters { waiter.resume() }
    }

    private static func exitError(status: Int32, detail: String) -> BrainConversationError {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if lowered.contains("not authenticated") || lowered.contains("authentication") || lowered.contains("copilot login")
            || lowered.contains("/login") {
            return .authentication(trimmed)
        }
        return .exited(status: status, detail: String(trimmed.suffix(2000)))
    }

    // MARK: Messages

    private func request(_ method: String, _ parameters: JSONValue, timeout: TimeInterval?) async -> Reply {
        await withCheckedContinuation { (continuation: CheckedContinuation<Reply, Never>) in
            let registered: Int? = lock.withLock {
                guard exitStatus == nil, !isClosed else { return nil }
                let id = nextRequestID
                nextRequestID += 1
                pending[id] = continuation
                return id
            }
            guard let id = registered else {
                let status = lock.withLock { exitStatus }
                continuation.resume(returning: .failure(
                    status.map { Self.exitError(status: $0, detail: lock.withLock { String(decoding: errorTail, as: UTF8.self) }) }
                        ?? .protocolViolation("Spojení s Agentem je ukončené.")
                ))
                return
            }
            send(.object([
                "jsonrpc": .string("2.0"),
                "id": .number(Double(id)),
                "method": .string(method),
                "params": parameters,
            ]))
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.resolve(id, with: .failure(.protocolViolation(
                        "Copilot CLI neodpověděl na \(method) do \(Int(timeout)) s."
                    )))
                }
            }
        }
    }

    private func resolve(_ id: Int, with reply: Reply) {
        let continuation = lock.withLock { pending.removeValue(forKey: id) }
        continuation?.resume(returning: reply)
    }

    private func send(_ message: JSONValue) {
        guard var encoded = try? JSONEncoder().encode(message) else { return }
        encoded.append(0x0A)
        let data = encoded
        writeQueue.async { [weak self] in
            guard let self else { return }
            let descriptor = self.lock.withLock { self.inputDescriptor }
            guard descriptor >= 0 else { return }
            data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written == -1 && errno == EINTR {
                        continue
                    } else {
                        return
                    }
                }
            }
        }
    }

    private func closeInput() {
        writeQueue.async { [weak self] in
            guard let self else { return }
            let descriptor: Int32 = self.lock.withLock {
                defer { self.inputDescriptor = -1 }
                return self.inputDescriptor
            }
            if descriptor >= 0 { Darwin.close(descriptor) }
        }
    }

    private func receive(_ data: Data) {
        let lines: [Data] = lock.withLock {
            outputBuffer.append(data)
            var lines: [Data] = []
            while let newline = outputBuffer.firstIndex(of: 0x0A) {
                lines.append(outputBuffer[outputBuffer.startIndex..<newline])
                outputBuffer.removeSubrange(outputBuffer.startIndex...newline)
            }
            return lines
        }
        for line in lines where !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D }) {
            guard let message = try? decoder.decode(JSONValue.self, from: line), case .object = message else {
                receiveError(line + Data([0x0A]))
                continue
            }
            handle(message)
        }
    }

    private func receiveError(_ data: Data) {
        lock.withLock {
            errorTail.append(data)
            if errorTail.count > 16_384 { errorTail = Data(errorTail.suffix(8_192)) }
        }
    }

    private func handle(_ message: JSONValue) {
        if let method = message["method"]?.stringValue {
            if let id = message["id"] {
                answerAgentRequest(id: id, method: method, parameters: message["params"] ?? .null)
            } else if method == "session/update" {
                deliver(message["params"] ?? .null)
            }
            return
        }
        guard let id = message["id"]?.intValue else { return }
        if let error = message["error"] {
            let text = error["message"]?.stringValue ?? "Neznámá chyba"
            let code = error["code"]?.intValue
            let detail = [text, error["data"].map { "\($0)" }].compactMap { $0 }.joined(separator: " ")
            if code == -32000 || text.lowercased().contains("auth") {
                resolve(id, with: .failure(.authentication(detail)))
            } else {
                resolve(id, with: .failure(.agent(detail)))
            }
        } else {
            resolve(id, with: .success(message["result"] ?? .null))
        }
    }

    private func deliver(_ parameters: JSONValue) {
        let handler: (@Sendable (ACPSessionEvent) -> Void)? = lock.withLock {
            parameters["sessionId"]?.stringValue == attachedSession ? eventHandler : nil
        }
        guard let handler, let update = parameters["update"] else { return }
        if let event = Self.event(from: update) { handler(event) }
        if let event = Self.detailsEvent(from: update) { handler(event) }
    }

    static func detailsEvent(from update: JSONValue) -> ACPSessionEvent? {
        guard ["tool_call", "tool_call_update"].contains(update["sessionUpdate"]?.stringValue ?? ""),
              let id = update["toolCallId"]?.stringValue else { return nil }
        let details = ACPToolCallDetails(
            input: update["rawInput"], output: update["rawOutput"],
            content: update["content"]?.arrayValue, locations: update["locations"]?.arrayValue,
            kind: update["kind"]?.stringValue
        )
        return details == ACPToolCallDetails() ? nil : .toolDetails(id: id, details: details)
    }

    static func event(from update: JSONValue) -> ACPSessionEvent? {
        switch update["sessionUpdate"]?.stringValue {
        case "agent_message_chunk":
            guard update["content"]?["type"]?.stringValue == "text",
                  let text = update["content"]?["text"]?.stringValue
            else { return nil }
            return .answerChunk(text)
        case "tool_call":
            guard let id = update["toolCallId"]?.stringValue else { return nil }
            return .toolCall(
                id: id,
                title: update["title"]?.stringValue ?? "",
                kind: update["kind"]?.stringValue,
                status: update["status"]?.stringValue.flatMap(ACPToolCallStatus.init(rawValue:)) ?? .pending
            )
        case "tool_call_update":
            guard let id = update["toolCallId"]?.stringValue else { return nil }
            return .toolCallUpdate(
                id: id,
                title: update["title"]?.stringValue,
                status: update["status"]?.stringValue.flatMap(ACPToolCallStatus.init(rawValue:))
            )
        default:
            return nil
        }
    }

    /// Requests from the Agent. Permission requests are allowed and reported; the
    /// client offers no file system or terminal methods, so everything else is refused.
    private func answerAgentRequest(id: JSONValue, method: String, parameters: JSONValue) {
        guard method == "session/request_permission" else {
            send(.object([
                "jsonrpc": .string("2.0"),
                "id": id,
                "error": .object(["code": .number(-32601), "message": .string("Method not found: \(method)")]),
            ]))
            return
        }
        let options = parameters["options"]?.arrayValue ?? []
        let preferred = ["allow_once", "allow_always"]
        let option = preferred.lazy.compactMap { kind in options.first { $0["kind"]?.stringValue == kind } }.first
            ?? options.first { $0["kind"]?.stringValue?.hasPrefix("allow") == true }
        let outcome: JSONValue
        if let option, let optionID = option["optionId"]?.stringValue {
            outcome = .object(["outcome": .string("selected"), "optionId": .string(optionID)])
        } else {
            outcome = .object(["outcome": .string("cancelled")])
        }
        send(.object(["jsonrpc": .string("2.0"), "id": id, "result": .object(["outcome": outcome])]))

        let handler = lock.withLock {
            parameters["sessionId"]?.stringValue == attachedSession ? eventHandler : nil
        }
        let title = parameters["toolCall"]?["title"]?.stringValue
            ?? parameters["toolCall"]?["toolCallId"]?.stringValue ?? method
        let chosen = option?["name"]?.stringValue ?? option?["optionId"]?.stringValue ?? "žádná možnost povolení"
        handler?(.permissionAllowed(title: title, option: chosen))
        if let call = parameters["toolCall"], let id = call["toolCallId"]?.stringValue {
            let details = ACPToolCallDetails(
                input: call["rawInput"], output: call["rawOutput"], content: call["content"]?.arrayValue,
                locations: call["locations"]?.arrayValue, kind: call["kind"]?.stringValue
            )
            if details != ACPToolCallDetails() { handler?(.toolDetails(id: id, details: details)) }
        }
    }

    // MARK: Cancel and termination

    private func cancelPrompt(session: String, token: Int) {
        send(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("session/cancel"),
            "params": .object(["sessionId": .string(session)]),
        ]))
        DispatchQueue.global().asyncAfter(deadline: .now() + configuration.cancelGracePeriod) { [weak self] in
            guard let self, self.lock.withLock({ self.activePrompt == token }) else { return }
            self.terminateGroup()
        }
    }

    /// Starts terminating the process group without waiting; pending requests then fail.
    private func terminateGroup() {
        let processID: pid_t? = lock.withLock {
            isClosed = true
            return groupGone ? nil : self.processID
        }
        guard let processID else { return }
        let grace = configuration.terminationGracePeriod
        Task.detached { [weak self] in
            guard let self, self.groupExists(processID) else { return }
            kill(-processID, SIGTERM)
            await self.waitUntilGroupExits(processID, timeout: grace)
            if self.groupExists(processID) { kill(-processID, SIGKILL) }
        }
    }

    private func waitForLeaderExit() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock {
                if processID == nil || exitStatus != nil { return true }
                exitWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    private func waitUntilGroupExits(_ processGroupID: pid_t, timeout: TimeInterval) async {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while groupExists(processGroupID), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func groupExists(_ processGroupID: pid_t) -> Bool {
        guard processGroupID > 1, processGroupID != getpgrp() else { return false }
        if kill(-processGroupID, 0) == 0 { return true }
        return errno != ESRCH
    }

    // MARK: Process plumbing

    private static func offCooperativePool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: work()) }
        }
    }

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors = [Int32](repeating: -1, count: 2)
        let result = descriptors.withUnsafeMutableBufferPointer { Darwin.pipe($0.baseAddress!) }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        for descriptor in descriptors {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
        return (descriptors[0], descriptors[1])
    }

    private static func spawn(
        _ executable: URL,
        arguments: [String],
        environment: [String: String],
        directory: String,
        input: Int32,
        output: Int32,
        errors: Int32,
        close parentDescriptors: [Int32]
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        try check(posix_spawn_file_actions_adddup2(&fileActions, input, STDIN_FILENO))
        try check(posix_spawn_file_actions_adddup2(&fileActions, output, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&fileActions, errors, STDERR_FILENO))
        for descriptor in parentDescriptors + [input, output, errors] where descriptor > STDERR_FILENO {
            try check(posix_spawn_file_actions_addclose(&fileActions, descriptor))
        }
        try check(posix_spawn_file_actions_addchdir_np(&fileActions, directory))

        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGTERM)
        sigaddset(&defaultSignals, SIGPIPE)
        try check(posix_spawnattr_setsigdefault(&attributes, &defaultSignals))
        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        try check(posix_spawnattr_setsigmask(&attributes, &signalMask))
        try check(posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        ))
        try check(posix_spawnattr_setpgroup(&attributes, 0))

        let path = executable.path(percentEncoded: false)
        var argv = [strdup(path)] + arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }

        var processID: pid_t = 0
        let result = argv.withUnsafeMutableBufferPointer { argvBuffer in
            envp.withUnsafeMutableBufferPointer { envpBuffer in
                posix_spawn(&processID, path, &fileActions, &attributes, argvBuffer.baseAddress!, envpBuffer.baseAddress!)
            }
        }
        try check(result)
        return processID
    }

    private static func check(_ result: Int32) throws {
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
