# Brain Conversation: structured Copilot CLI feasibility (#109)

Evidence for the #108 prerequisite.

Setup:
- Copilot CLI 1.0.103 in ACP mode (`copilot --acp`), model `claude-haiku-4.5`.
- Inert fixtures under `/tmp/n109/<scenario>`, each with `Daily Entries/`, `Free Notes/` and `_brain/`.
- Harness: `scripts/brain-conversation-probe/`. Run `scenarios.py <name> [copilot args]`; results go to `/tmp/n109-results/`.
- The host policy in every scenario is enforced by the probe's permission callback. No scenario relies on a prompt rule.

## Verdict

**No-go for #108 as written. Conditional go for a host-mediated design with changed requirements.**

What the CLI enforces:
- read scope
- per-request approval
- cancellation
- prevention by removing tools through the tool allowlist

What it does not enforce:
- target-scoped grants
- drift-safe writes
- any boundary on shell

The viable architecture removes the CLI's general tools. Every side effect goes through a host-owned MCP tool that Notess executes itself. That architecture still has one open reliability blocker (see "Open").

## Evidence

| # | Scenario | Result |
|---|----------|--------|
| 1 | `tools_default` | A default ACP session exposes `bash`, `web_fetch`, `task` (subagents), `sql`, `skill`, workflows and every user-global MCP server (e.g. `workiq-*`). `--disable-builtin-mcps` removes only the GitHub servers. |
| 2 | `tools_default@restricted`, `--available-tools view grep glob create edit` | The CLI disables all other tools, including user MCP tools, and reports the disabled list. The CLI enforces this, not the prompt. |
| 3 | `deny` | `create` sends `session/request_permission` with the full path and diff. On `reject_once` the file is not written, the tool call is marked `failed` and the turn ends with `end_turn`. |
| 4 | `protected` | An edit to `Daily Entries/…` arrives with its real path and diff. The host rejects it and the file stays unchanged. |
| 5 | `alias` | Edits through a symlink and a hardlink in `_brain/` show **only the alias path**. The CLI does not resolve them; the host must (`realpath`, `st_nlink`). |
| 6 | `always` | `allow_always` on `_brain/a.md` silently authorised a later create in `Free Notes/b.md`: **the CLI grant applies to the tool kind, not the target**. Shell commands still asked. After a process restart, `session/load` replayed 13 history events and asked for permission again, so **grants are not restored**. |
| 7 | `reads` | Reads inside cwd do not ask. A read outside cwd asks ("Access paths outside trusted directories", with the path). Rejected, the file is not read. The temp dir is trusted by default; `--disallow-temp-dir` exists. |
| 8 | `web` | `web_fetch` asks with the full URL, including the note-derived payload (`?word=PELICAN`). Rejected, the local server receives no hits. |
| 9 | `drift` | The target was edited while the approval was pending. After `allow_once` the CLI wrote its stale content and **lost the concurrent edit**. |
| 10 | `cancel_pending` | `session/cancel`, plus a `cancelled` outcome for the pending permission, ends the turn with `stopReason: cancelled`; the file is not written. |
| 11 | `cancel_running` | Cancel during an approved `sleep 60` shell command ends the turn as `cancelled` within ~6 s. The `sleep` processes are gone and no process-group leftovers remain. |
| 12 | `unprompted` | `task` spawned a background subagent **without any permission request**. Its tool events carry `_meta.agentId`. |
| 13 | `acpmcp` | A stdio MCP server passed in ACP `session/new.mcpServers` was **ignored**: its tool was not available. |
| 14 | `hostmcp` | A host MCP server passed via `--additional-mcp-config` loads as `notess-host-propose_edit`. Its call asks permission (`kind: other`, full arguments in `rawInput`). After approval the host process receives the full payload and decides what happens; the CLI writes nothing itself. |

## Capability matrix

| #108 requirement | Status |
|------------------|--------|
| Bidirectional turns, streamed activity, approval request/response | Demonstrated (ACP). |
| Approval blocks execution; a denied action does not execute | Demonstrated (3, 4, 8). |
| Cancel during work or during a pending approval; process cleanup | Demonstrated (10, 11). On Vault switch or quit the host must also kill the process group. |
| Resume with fresh authority | Demonstrated (6). `session/load` replays the transcript and restores no grants. |
| Reading additional local folders needs approval | Demonstrated (7), provided the temp dir is disallowed and no `--add-dir` is passed. |
| No direct writes to original notes via edit/create | Host-enforceable by rejecting on the resolved path (4, 5). Safer: remove `create`/`edit` (2) and use host tools (14). |
| No route via shell | **Not enforceable.** The host sees only command text, arbitrary commands can write anywhere, and prefix rules cannot bound them. Only removing shell works. |
| No route via integrations | **Not enforceable per payload for arbitrary user MCP servers.** Removing them via the allowlist works (2). |
| Path aliases | Enforceable only if the host performs the write (5, 14). |
| Drift detection before apply | **Fails when the CLI writes** (9). Enforceable with host-owned write tools (14). |
| Targeted, revocable, expiring grants | **Not possible with CLI `allow_always`** (6). Host-side alternative: never offer `allow_always`; the host answers `allow_once` automatically for requests that match one of its own grants. |
| Per-payload transmission approval | For `web_fetch`, per-request approval shows the full URL (8). A domain grant would not authorise individual payloads. Other egress paths (shell, MCP) require removal. |
| Subagents follow the same policy | Not demonstrated (12). Remove `task` and the agent tools. |
| No replay of completed side effects; uncertain outcomes | The host's responsibility once side effects are host tools. Not testable at the CLI level. |

## Proposed changes to #108

1. **Tool surface by allowlist.** Use `--available-tools` to allow the read tools (`view`, `grep`, `glob`), optionally `web_fetch`, and Notess host tools only. Also pass `--disable-builtin-mcps --disallow-temp-dir`. User integrations, shell, subagents, skills and workflows are out of v1, so stories 15 and 21 lose shell and integrations.
2. **All side effects are host tools.** Notess provides an MCP server via `--additional-mcp-config` (not ACP `mcpServers`). Example tools:
   - `propose_note_edit`: opens an editor proposal for Daily Entries and Free Notes.
   - `apply_brain_edit`: the host writes after approval, after checking a base fingerprint and resolving the real path.
   Stories 27–30 are then satisfied by construction.
3. **Grants live in the host.** Never pass `allow_always` to the CLI. A grant is a host rule that answers `allow_once` automatically for matching requests. Grants are held in memory, can be inspected and revoked, and expire when the conversation closes.
4. **Transmission.** Every `web_fetch` is approved individually with its full URL shown. Either drop domain grants, or explicitly accept that a domain grant authorises any payload to that domain.
5. **Resume.** Persist the ACP `sessionId` per Vault, outside the Vault. Use `session/load` for the transcript; authority always starts empty.

## Open

- **Turn completion with host MCP tools is unreliable, cause unknown (CLI or harness).** It must be root-caused before choosing the host-tool architecture.
  - In several runs the final assistant message streamed, but the `session/prompt` response did not arrive within 150–180 s.
  - One run took 147 s.
  - The same prompt sometimes completed in under 10 s.
- **The ACP `session/new.mcpServers` route was ignored.** This may be a CLI limitation or a schema mismatch. `--additional-mcp-config` works, but fixes the host tools for the whole process.
- **Still untested:**
  - handling of uncertain outcomes
  - real investigation quality: an answer from Brain Notes, fallback disclosure, and a no-evidence answer

## Simplified option: read-only Vault, unrestricted shell and web

Proposed scope reduction:
- The Agent never writes.
- Shell and web are allowed without approval.

The CLI cannot enforce "never writes" while shell is available. The OS can. In one fixture run, the `copilot --acp` process was wrapped in macOS `sandbox-exec`, with the profile `(allow default)(deny file-write* (subpath "<vault realpath>"))` (`scripts/brain-conversation-probe/sandbox-wrap.sh`). The run used `--allow-all-tools`. A shell `echo >> 'Daily Entries/d.md'` failed with `Operation not permitted` and the note was unchanged. `cat` of the same file still worked.

Because the kernel applies the rule to the whole process tree, it covers shell, aliases, subagents and MCP servers. This is separate from the app's App Sandbox, which ADR 0004 keeps off.

This option removes approvals, grants, drift and alias handling, and the need for host write tools. What remains and what is given up:
- **Transmission and side-effect approvals are given up.** #108 stories 17, 18 and 20–26 no longer apply: note content can leave through web or shell without asking.
- **Reads outside the Vault go unapproved.** They are only limited by `--add-dir`/trust prompts, which stop working once all tools are allowed.
- **`sandbox-exec` is deprecated.** It still works, but if it becomes unavailable, Notess must refuse to start a conversation rather than run without the write boundary.
- **Shell side effects outside the Vault remain possible.** This includes writes elsewhere and calls to other services.
