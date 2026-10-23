import Foundation
import Testing
@testable import NotessCore

/// A scripted ACP agent standing in for Copilot CLI, launched through the real sandbox.
/// It records what it saw in a marker folder outside the Vault.
private final class FakeAgent {
    enum Mode: String {
        case normal, writeVault, holdHonoringCancel, holdIgnoringCancel, exitDuringPrompt, authRequired, silent
    }

    let base: URL
    let vault: Vault
    let markers: URL
    let executable: URL

    init(_ mode: Mode) throws {
        base = FileManager.default.temporaryDirectory
            .appending(path: "NotessACP-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = base.appending(path: "Vault", directoryHint: .isDirectory)
        markers = base.appending(path: "markers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "_brain"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        try "Alice is the codeword keeper.\n".write(to: root.appending(path: "_brain/Alice.md"), atomically: true, encoding: .utf8)
        vault = Vault(rootURL: root)
        executable = base.appending(path: "fake-copilot")
        try Self.script(mode: mode, markers: markers.path(percentEncoded: false))
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    func connection(
        sandbox: URL = VaultWriteSandbox.defaultExecutableURL,
        startupTimeout: TimeInterval = 20,
        additionalArguments: [String] = []
    ) -> CopilotACPConnection {
        CopilotACPConnection(vault: vault, configuration: .init(
            executableURL: executable,
            sandboxExecutableURL: sandbox,
            startupTimeout: startupTimeout,
            cancelGracePeriod: 0.5,
            terminationGracePeriod: 1,
            additionalArguments: additionalArguments
        ))
    }

    func marker(_ name: String) -> String? {
        try? String(contentsOf: markers.appending(path: name), encoding: .utf8)
    }

    var vaultEntries: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: vault.rootURL.path(percentEncoded: false)).sorted()) ?? []
    }

    private static func script(mode: Mode, markers: String) -> String {
        """
        #!/usr/bin/python3
        import json, os, subprocess, sys
        MODE = "\(mode.rawValue)"
        MARKERS = \(String(reflecting: markers))
        def mark(name, text):
            with open(os.path.join(MARKERS, name), "a") as f:
                f.write(text)
        mark("launches", "x")
        mark("arguments", " ".join(sys.argv[1:]))
        def send(message):
            sys.stdout.write(json.dumps(message) + "\\n")
            sys.stdout.flush()
        def update(session, payload):
            send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session, "update": payload}})
        def read():
            line = sys.stdin.readline()
            return json.loads(line) if line else None
        turns = 0
        while True:
            message = read()
            if message is None:
                break
            method, rid = message.get("method"), message.get("id")
            if method == "initialize":
                if MODE == "silent":
                    continue
                if MODE == "authRequired":
                    send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32000, "message": "Authentication required"}})
                    continue
                send({"jsonrpc": "2.0", "id": rid, "result": {"protocolVersion": 1, "agentCapabilities": {}}})
            elif method == "session/new":
                mark("cwd", message["params"]["cwd"])
                send({"jsonrpc": "2.0", "id": rid, "result": {"sessionId": "s1"}})
            elif method == "session/prompt":
                turns += 1
                blocks = message["params"]["prompt"]
                mark("prompts", json.dumps([b["text"] for b in blocks]) + "\\n")
                question = blocks[-1]["text"]
                if MODE == "exitDuringPrompt":
                    update("s1", {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "partial"}})
                    sys.stderr.write("fatal: something broke\\n")
                    sys.exit(3)
                update("s1", {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "hidden"}})
                update("s1", {"sessionUpdate": "tool_call", "toolCallId": "t%d" % turns, "title": "Read _brain/Alice.md", "kind": "read", "status": "pending"})
                send({"jsonrpc": "2.0", "id": "perm%d" % turns, "method": "session/request_permission", "params": {"sessionId": "s1",
                      "toolCall": {"toolCallId": "t%d" % turns, "title": "Read _brain/Alice.md"},
                      "options": [{"optionId": "reject", "name": "Reject", "kind": "reject_once"},
                                  {"optionId": "allow", "name": "Allow once", "kind": "allow_once"}]}})
                reply = read()
                mark("permission", json.dumps(reply.get("result")) + "\\n")
                send({"jsonrpc": "2.0", "id": 99, "method": "fs/read_text_file", "params": {"sessionId": "s1", "path": "x"}})
                mark("fs", json.dumps(read().get("error", {}).get("code")))
                update("s1", {"sessionUpdate": "tool_call_update", "toolCallId": "t%d" % turns, "status": "completed"})
                answer = "Echo: " + question
                if MODE == "writeVault":
                    try:
                        with open("Stolen.md", "w") as f:
                            f.write("x")
                        answer = "wrote"
                    except OSError as error:
                        answer = "blocked " + error.strerror
                if MODE in ("holdHonoringCancel", "holdIgnoringCancel"):
                    child = subprocess.Popen(["/bin/sleep", "300"])
                    mark("child", str(child.pid))
                    update("s1", {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "partial"}})
                    while True:
                        incoming = read()
                        if incoming is None:
                            sys.exit(0)
                        if incoming.get("method") == "session/cancel":
                            mark("cancel", incoming["params"]["sessionId"])
                            if MODE == "holdHonoringCancel":
                                child.kill()
                                send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled"}})
                                break
                    continue
                for piece in (answer[:3], answer[3:]):
                    update("s1", {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": piece}})
                send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        """
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ACPSessionEvent] = []
    func append(_ event: ACPSessionEvent) { lock.withLock { events.append(event) } }
    var all: [ACPSessionEvent] { lock.withLock { events } }
    var answer: String {
        all.compactMap { if case .answerChunk(let text) = $0 { return text } else { return nil } }.joined()
    }
}

private func processExists(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno != ESRCH
}

@Suite("Copilot ACP connection")
struct CopilotACPConnectionTests {
    @Test("multi-turn prompts share one sandboxed session and stream answers, activity and allowed permissions")
    func multiTurn() async throws {
        let agent = try FakeAgent(.normal)
        let connection = agent.connection(additionalArguments: ["--disable-mcp-server", "extra-server"])
        try await connection.start()

        let first = EventLog()
        let stop1 = try await connection.prompt(["instructions", "one"], events: first.append)
        let second = EventLog()
        let stop2 = try await connection.prompt(["two"], events: second.append)

        #expect(stop1 == .endTurn)
        #expect(stop2 == .endTurn)
        #expect(first.answer == "Echo: one")
        #expect(second.answer == "Echo: two")
        #expect(first.all.contains(.toolCall(id: "t1", title: "Read _brain/Alice.md", kind: "read", status: .pending)))
        #expect(first.all.contains(.toolCallUpdate(id: "t1", title: nil, status: .completed)))
        #expect(first.all.contains(.permissionAllowed(title: "Read _brain/Alice.md", option: "Allow once")))
        #expect(agent.marker("launches") == "x")
        #expect(agent.marker("permission")?.contains(#""optionId": "allow""#) == true)
        #expect(agent.marker("fs") == "-32601-32601")
        let realVault = try #require(try? VaultWriteSandbox(vault: agent.vault).vaultRealPath)
        #expect(agent.marker("cwd") == realVault)
        let arguments = try #require(agent.marker("arguments"))
        #expect(arguments.contains("--acp"))
        #expect(arguments.contains("--allow-all"))
        #expect(arguments.contains("--disable-builtin-mcps"))
        #expect(arguments.hasSuffix("--disable-mcp-server extra-server"))
        #expect(await connection.isOpen())

        await connection.close()
        #expect(!(await connection.isOpen()))
    }

    @Test("the Agent's process tree cannot write into the Vault")
    func agentWriteIsBlocked() async throws {
        let agent = try FakeAgent(.writeVault)
        let connection = agent.connection()
        try await connection.start()

        let log = EventLog()
        _ = try await connection.prompt(["try"], events: log.append)
        await connection.close()

        #expect(log.answer == "blocked Operation not permitted")
        #expect(agent.vaultEntries == ["_brain"])
    }

    @Test("launch fails closed when the sandbox is unavailable: the Agent never starts")
    func failsClosedWithoutSandbox() async throws {
        let agent = try FakeAgent(.normal)
        let connection = agent.connection(sandbox: URL(filePath: "/nonexistent/sandbox-exec"))

        await #expect {
            try await connection.start()
        } throws: { error in
            guard case .sandbox(.unavailable) = error as? BrainConversationError else { return false }
            return true
        }
        #expect(agent.marker("launches") == nil)
        #expect(!(await connection.isOpen()))
    }

    @Test("Stop sends session/cancel and the turn ends as cancelled when the Agent honours it")
    func cancelHonoured() async throws {
        let agent = try FakeAgent(.holdHonoringCancel)
        let connection = agent.connection()
        try await connection.start()
        let log = EventLog()

        let turn = Task { try await connection.prompt(["wait"], events: log.append) }
        try await waitUntil { agent.marker("child") != nil && log.answer == "partial" }
        turn.cancel()
        let stop = try await turn.value

        #expect(stop == .cancelled)
        #expect(agent.marker("cancel") == "s1")
        #expect(await connection.isOpen())
        await connection.close()
    }

    @Test("Stop terminates the owned process group when the Agent ignores session/cancel")
    func cancelIgnoredTerminatesGroup() async throws {
        let agent = try FakeAgent(.holdIgnoringCancel)
        let connection = agent.connection()
        try await connection.start()

        let turn = Task { try await connection.prompt(["wait"], events: { _ in }) }
        try await waitUntil { agent.marker("child") != nil }
        let child = try #require(agent.marker("child").flatMap { pid_t($0) })
        turn.cancel()
        let stop = try await turn.value

        #expect(stop == .cancelled)
        #expect(agent.marker("cancel") == "s1")
        #expect(!processExists(child))
        #expect(!(await connection.isOpen()))
        await connection.close()
    }

    @Test("closing terminates the process group and can be repeated")
    func closeTerminatesGroup() async throws {
        let agent = try FakeAgent(.holdIgnoringCancel)
        let connection = agent.connection()
        try await connection.start()
        let turn = Task { try? await connection.prompt(["wait"], events: { _ in }) }
        try await waitUntil { agent.marker("child") != nil }
        let child = try #require(agent.marker("child").flatMap { pid_t($0) })

        await connection.close()
        await connection.close()
        _ = await turn.value

        #expect(!processExists(child))
    }

    @Test("a process that exits before session/prompt answers is an error, not an answer")
    func exitIsError() async throws {
        let agent = try FakeAgent(.exitDuringPrompt)
        let connection = agent.connection()
        try await connection.start()

        await #expect {
            _ = try await connection.prompt(["boom"], events: { _ in })
        } throws: { error in
            guard case .exited(let status, let detail) = error as? BrainConversationError else { return false }
            return status == 3 && detail.contains("something broke")
        }
        #expect(!(await connection.isOpen()))
        await connection.close()
    }

    @Test("an authentication error is reported as such")
    func authenticationError() async throws {
        let agent = try FakeAgent(.authRequired)
        let connection = agent.connection()

        await #expect {
            try await connection.start()
        } throws: { error in
            guard case .authentication = error as? BrainConversationError else { return false }
            return true
        }
        await connection.close()
    }

    @Test("an Agent that never answers initialize is a protocol failure")
    func startupTimeout() async throws {
        let agent = try FakeAgent(.silent)
        let connection = agent.connection(startupTimeout: 0.5)

        await #expect {
            try await connection.start()
        } throws: { error in
            guard case .protocolViolation = error as? BrainConversationError else { return false }
            return true
        }
        await connection.close()
    }

    @Test("ACP updates map to events; reasoning chunks are dropped")
    func eventMapping() {
        let chunk: JSONValue = .object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string("Hi")]),
        ])
        let thought: JSONValue = .object([
            "sessionUpdate": .string("agent_thought_chunk"),
            "content": .object(["type": .string("text"), "text": .string("hmm")]),
        ])
        let update: JSONValue = .object([
            "sessionUpdate": .string("tool_call_update"),
            "toolCallId": .string("t"),
            "status": .string("failed"),
        ])

        #expect(CopilotACPConnection.event(from: chunk) == .answerChunk("Hi"))
        #expect(CopilotACPConnection.event(from: thought) == nil)
        #expect(CopilotACPConnection.event(from: update) == .toolCallUpdate(id: "t", title: nil, status: .failed))
    }
}

func waitUntil(timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        try #require(ContinuousClock.now < deadline, "timed out")
        try await Task.sleep(for: .milliseconds(10))
    }
}
