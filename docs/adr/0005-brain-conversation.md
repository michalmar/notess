---
status: proposed
---

# Brain Conversation is a read-only Agent conversation with OS-enforced write protection

Fulltext search cannot investigate a question across several Brain Notes or support follow-up questions. We add a Brain Conversation backed by Copilot CLI, separate from the non-interactive Brain Run. The design is approved; its implementation proceeds in slices, so this record describes the intended behaviour rather than what already ships.

## Conversation and evidence

The conversation appears in a right-hand panel beside the note editor. Follow-up questions retain context, and clickable note links open in the editor without replacing the panel. Answers distinguish evidence from Brain Notes, original notes and external sources, and acknowledge insufficient evidence instead of presenting it as established.

The Agent starts with Brain Notes. If they lack sufficient evidence it consults saved Daily Entries and Free Notes without asking again and discloses that in its answer. Unsaved editor changes are never inputs. Tool activity (commands, fetched URLs, files read) is shown as an activity record, not as the model's hidden reasoning.

A Brain Conversation does not advance the last-successful-Brain-Run baseline or mark changed notes as processed. Answer links do not change a Citation, which still connects a fact in a Brain Note to its original Section.

## The Agent never writes to the Vault

The Agent cannot change any file in the Vault through any tool. The operating system enforces this, not the prompt and not CLI permissions: Copilot CLI is spawned under a macOS Seatbelt profile (`sandbox-exec`) that denies file writes inside the Vault's real path. If that protection cannot be applied, the Brain Conversation refuses to start.

Shell, web and writes outside the Vault are deliberately unrestricted, and there are no approvals or grants. An earlier design with per-action approvals and targeted grants was dropped after the feasibility investigation found that CLI grants are tool-kind-wide rather than target-specific, that CLI writes lose concurrent edits, and that shell cannot be bounded by CLI permissions, while an OS write sandbox blocks Vault writes from every tool, including shell.

This is stricter than [ADR-0002](0002-markdown-files-are-source-of-truth.md), which lets a Brain Run write `_brain/`. The Brain Run is unchanged and remains a separate operation; the App Sandbox stays off ([ADR-0004](0004-no-app-sandbox.md)) and the Seatbelt profile covers only the spawned CLI process tree. The deprecation risk of `sandbox-exec` is accepted; the fallback is a VM or container with a read-only Vault mount.

## Persistence and lifecycle

History is stored outside the Vault, separately for each Vault, and can be reopened and continued after a restart. Switching Vaults or quitting stops active work while preserving history, and nothing from the previous Vault enters another Vault's conversation.

At most one Agent operation, either a Brain Run or a conversation turn, owns a Vault at a time. The Vault stays owned until cancellation and the cleanup of the processes the operation owns have finished, so repeated cancellation, Vault changes and quit cannot release it early, and late events from a stopped operation are ignored. Both operation kinds share this ownership and cleanup, but not a transport or a success record: a Brain Run is completion-oriented, a conversation turn streams over ACP.

Notes stay viewable and editable during a turn; the next message is submitted only after the turn finishes or is stopped. There is no fixed step limit. The panel shows activity, elapsed time and Stop; stopped output is marked incomplete and failures are reported explicitly.

## Considered options

Extending Brain Run would mix incremental note processing with conversation. An external terminal would not give the in-app evidence experience. Approval-gated writes were considered and rejected as above; any future Agent writes need a separate decision.
