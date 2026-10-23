"""Minimal ACP (JSON-RPC over stdio) client for Copilot CLI experiments."""

import json
import os
import queue
import subprocess
import threading
import time

COPILOT = os.environ.get("COPILOT_BIN", "/opt/homebrew/bin/copilot")


class ACP:
    def __init__(self, cwd, extra_args=(), env=None, model="claude-haiku-4.5", log=None):
        args = [COPILOT, "--acp", "-C", str(cwd), "--disable-client-telemetry", *extra_args]
        if model:
            args += ["--model", model]
        self.args = args
        e = dict(os.environ)
        e.pop("COPILOT_ALLOW_ALL", None)
        if env:
            e.update(env)
        self.p = subprocess.Popen(
            args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1, env=e, start_new_session=True,
        )
        self.q = queue.Queue()
        self.log = log if log is not None else []
        self.next_id = 1000
        self.on_permission = lambda req: {"outcome": {"outcome": "cancelled"}}
        self.on_request = None
        threading.Thread(target=self._reader, daemon=True).start()
        threading.Thread(target=self._err, daemon=True).start()
        self.stderr = []

    def _err(self):
        for line in self.p.stderr:
            self.stderr.append(line)

    def _reader(self):
        for line in self.p.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                self.log.append({"_raw": line})
                continue
            self.log.append(msg)
            self.q.put(msg)
        self.q.put(None)

    def send(self, msg):
        self.p.stdin.write(json.dumps(msg) + "\n")
        self.p.stdin.flush()

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def _handle_incoming_request(self, msg):
        if msg["method"] == "session/request_permission":
            result = self.on_permission(msg)
            if result is not None:
                self.send({"jsonrpc": "2.0", "id": msg["id"], "result": result})
        elif self.on_request:
            self.on_request(msg)
        else:
            self.send({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": "not supported"}})

    def request(self, method, params, timeout=180, on_event=None):
        rid = self.next_id
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        return self.wait_response(rid, timeout, on_event)

    def wait_response(self, rid, timeout=180, on_event=None):
        deadline = time.monotonic() + timeout
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                raise TimeoutError(f"no response to {rid}")
            try:
                msg = self.q.get(timeout=left)
            except queue.Empty:
                raise TimeoutError(f"no response to {rid}")
            if msg is None:
                raise EOFError("ACP process exited")
            if "method" in msg and "id" in msg:
                self._handle_incoming_request(msg)
            elif "method" in msg:
                if on_event:
                    on_event(msg)
            elif msg.get("id") == rid:
                return msg

    def initialize(self, fs=False):
        caps = {"fs": {"readTextFile": fs, "writeTextFile": fs}, "terminal": False}
        return self.request("initialize", {"protocolVersion": 1, "clientCapabilities": caps}, 60)

    def new_session(self, cwd, mcp_servers=()):
        r = self.request("session/new", {"cwd": str(cwd), "mcpServers": list(mcp_servers)}, 120)
        self.session_id = r["result"]["sessionId"]
        return r

    def load_session(self, cwd, session_id, mcp_servers=()):
        replay = []
        r = self.request(
            "session/load",
            {"sessionId": session_id, "cwd": str(cwd), "mcpServers": list(mcp_servers)},
            120,
            on_event=replay.append,
        )
        self.session_id = session_id
        return r, replay

    def prompt(self, text, timeout=240, on_event=None):
        return self.request(
            "session/prompt",
            {"sessionId": self.session_id, "prompt": [{"type": "text", "text": text}]},
            timeout,
            on_event,
        )

    def close(self):
        try:
            self.p.stdin.close()
        except Exception:
            pass
        try:
            self.p.terminate()
            self.p.wait(5)
        except Exception:
            self.p.kill()


def updates(events, kind=None):
    out = []
    for e in events:
        u = e.get("params", {}).get("update")
        if u and (kind is None or u.get("sessionUpdate") == kind):
            out.append(u)
    return out


def text_of(events):
    return "".join(
        u["content"].get("text", "")
        for u in updates(events, "agent_message_chunk")
        if isinstance(u.get("content"), dict)
    )


def tool_summary(events):
    out = []
    for u in updates(events):
        if u.get("sessionUpdate") in ("tool_call", "tool_call_update"):
            out.append({k: u.get(k) for k in ("sessionUpdate", "toolCallId", "title", "kind", "status", "rawInput", "locations", "_meta") if k in u})
    return out
