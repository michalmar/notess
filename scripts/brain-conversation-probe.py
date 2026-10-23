#!/usr/bin/env python3

import argparse
import json
import os
import shutil
import subprocess
import time
import uuid
import select
from pathlib import Path


def send(process, message):
    process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
    process.stdin.flush()


def read_until(process, predicate, timeout_seconds=60):
    deadline = time.monotonic() + timeout_seconds
    messages = []
    while time.monotonic() < deadline:
        line = process.stdout.readline()
        if not line:
            if process.poll() is not None:
                break
            continue
        message = json.loads(line)
        messages.append(message)
        if predicate(message):
            return message, messages
    raise TimeoutError("No matching ACP message received")


def read_line(process, timeout_seconds=60):
    ready, _, _ = select.select([process.stdout], [], [], timeout_seconds)
    if not ready:
        raise TimeoutError("ACP response timed out")
    line = process.stdout.readline()
    if not line:
        raise EOFError("ACP process closed stdout")
    return json.loads(line)


def start(copilot, fixture):
    return subprocess.Popen(
        [
            copilot,
            "--acp",
            "-C",
            str(fixture),
            "--disable-builtin-mcps",
            "--disable-client-telemetry",
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )


def initialize(process):
    send(
        process,
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": 1,
                "clientCapabilities": {
                    "fs": {"readTextFile": True, "writeTextFile": True},
                    "terminal": True,
                },
            },
        },
    )
    response, _ = read_until(process, lambda message: message.get("id") == 1)
    return response


def new_session(process, fixture):
    send(
        process,
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "session/new",
            "params": {"cwd": str(fixture), "mcpServers": []},
        },
    )
    session_id = None
    messages = []
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        line = process.stdout.readline()
        if not line:
            continue
        message = json.loads(line)
        messages.append(message)
        if message.get("id") == 2:
            session_id = message["result"]["sessionId"]
            break
    if session_id is None:
        raise TimeoutError("session/new did not return a session ID")
    return session_id, messages


def prompt(process, session_id, request_id, text):
    send(
        process,
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "session/prompt",
            "params": {
                "sessionId": session_id,
                "prompt": [{"type": "text", "text": text}],
            },
        },
    )


def close(process, session_id):
    send(
        process,
        {
            "jsonrpc": "2.0",
            "id": 900,
            "method": "session/close",
            "params": {"sessionId": session_id},
        },
    )
    response, _ = read_until(process, lambda message: message.get("id") == 900)
    return response


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--copilot", default="/opt/homebrew/bin/copilot")
    parser.add_argument("--fixture", default="/tmp/notess-issue109-fixture")
    args = parser.parse_args()

    fixture = Path(args.fixture)
    fixture.mkdir(parents=True, exist_ok=True)
    output_file = fixture / "fixture-output.txt"
    if output_file.exists():
        output_file.unlink()
    (fixture / "Daily Entries").mkdir(exist_ok=True)
    (fixture / "Free Notes").mkdir(exist_ok=True)
    (fixture / "_brain").mkdir(exist_ok=True)
    (fixture / "Daily Entries" / "fixture.md").write_text(
        "# Fixture Daily Entry\n\nPROTECTED_DAILY_ENTRY\n",
        encoding="utf-8",
    )
    (fixture / "Free Notes" / "fixture.md").write_text(
        "# Fixture Free Note\n\nPROTECTED_FREE_NOTE\n",
        encoding="utf-8",
    )

    process = start(args.copilot, fixture)
    evidence = {"copilot": args.copilot, "fixture": str(fixture)}
    try:
        init = initialize(process)
        evidence["initialize"] = init
        session_id, new_messages = new_session(process, fixture)
        evidence["sessionId"] = session_id
        evidence["newSessionEvents"] = [
            message for message in new_messages
            if message.get("method") == "session/update"
        ]

        prompt(
            process,
            session_id,
            3,
            (
                "Create fixture-output.txt containing exactly FIXTURE_OK. "
                "Do not use or modify any other file."
            ),
        )
        permission_request = None
        prompt_messages = []
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            ready, _, _ = select.select([process.stdout], [], [], 1)
            if not ready:
                continue
            message = json.loads(process.stdout.readline())
            prompt_messages.append(message)
            if message.get("method") == "session/request_permission":
                permission_request = message
                break
        evidence["promptEventsBeforePermission"] = prompt_messages
        evidence["permissionRequest"] = permission_request

        file_was_created = (fixture / "fixture-output.txt").exists()
        if permission_request is not None:
            send(
                process,
                {
                    "jsonrpc": "2.0",
                    "id": permission_request["id"],
                    "result": {
                        "outcome": {
                            "outcome": "selected",
                            "optionId": "allow_once",
                        }
                    },
                },
            )
        else:
            evidence["noPermissionRequest"] = True

        completion_messages = []
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            ready, _, _ = select.select([process.stdout], [], [], 1)
            if not ready:
                continue
            message = json.loads(process.stdout.readline())
            completion_messages.append(message)
            if message.get("id") == 3:
                evidence["promptCompletion"] = message
                break
        evidence["promptEventsAfterPermission"] = completion_messages
        evidence["fileContentBeforeFollowUp"] = (
            (fixture / "fixture-output.txt").read_text(encoding="utf-8")
            if (fixture / "fixture-output.txt").exists()
            else None
        )
        evidence["fileCreatedOnlyAfterPermission"] = (
            not file_was_created
            and evidence["fileContentBeforeFollowUp"] == "FIXTURE_OK\n"
        )

        prompt(
            process,
            session_id,
            4,
            "What file was just created? Reply with only its basename.",
        )
        follow_up_messages = []
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            ready, _, _ = select.select([process.stdout], [], [], 1)
            if not ready:
                continue
            message = json.loads(process.stdout.readline())
            follow_up_messages.append(message)
            if message.get("id") == 4:
                evidence["followUpCompletion"] = message
                break
        evidence["followUpEvents"] = follow_up_messages

        send(
            process,
            {
                "jsonrpc": "2.0",
                "method": "session/cancel",
                "params": {"sessionId": session_id},
            },
        )
        evidence["cancelSent"] = True
        evidence["close"] = close(process, session_id)
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)

    print(json.dumps(evidence, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
