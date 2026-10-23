---
status: accepted
---

# Brain Conversation is a read-only Agent conversation with OS-enforced write protection

Fulltext search cannot investigate a question across several Brain Notes or support follow-up questions. We add a Brain Conversation backed by Copilot CLI, separate from the non-interactive Brain Run. The design is approved and implemented in slices: the panel, follow-ups, Stop, OS write protection, inspectable evidence links and persistent history ship first; several conversations follow, so that part still describes intended behaviour.

## Conversation and evidence

The conversation appears in a right-hand panel beside the note editor. Follow-up questions retain context, and clickable note links open in the editor without replacing the panel. Answers distinguish evidence from Brain Notes, original notes and external sources, and acknowledge insufficient evidence instead of presenting it as established.

The Agent starts with Brain Notes. If they lack sufficient evidence it consults saved Daily Entries and Free Notes without asking again and discloses that in its answer. Unsaved editor changes are never inputs. Tool activity (commands, fetched URLs, files read) is shown as an activity record, not as the model's hidden reasoning.

Evidence uses existing wiki-link semantics (`[[Vault-relative note#Exact heading]]`) and HTTP(S) Markdown links. The panel resolves note categories from the Vault, provides clickable sources and routes note links through existing editor navigation: open tabs are selected before any disk read, including dirty or missing-on-disk notes, and Section lookup uses their current text. No source click reloads, saves or overwrites a draft, hides the conversation, or creates a missing note; invalid or missing targets report errors. Inspecting a draft does not send it to the Agent. Tool details retain only fields ACP supplies (raw input/output, content and locations), preserving earlier fields across sparse updates. Unexpected permission requests remain allowed and visible, not an approval workflow.

A Brain Conversation does not advance the last-successful-Brain-Run baseline or mark changed notes as processed. Answer links do not change a Citation, which still connects a fact in a Brain Note to its original Section.

## The Agent never writes to the Vault

The Agent cannot change any file in the Vault through any tool. The operating system enforces this, not the prompt and not CLI permissions: Copilot CLI is spawned under a macOS Seatbelt profile (`sandbox-exec`) that denies file writes inside the Vault's real path. If that protection cannot be applied, the Brain Conversation refuses to start. Before every launch Notess verifies that the profile blocks a probe write into the Vault and a change to the Vault's parent folder. Because the kernel checks the resolved path, symlinks into the Vault and new hard links to Vault files are blocked as well; an existing hard link outside the Vault to a Vault file would be a writable alias, so its presence also refuses the start. Every folder above the Vault is denied as an exact path, so the Agent cannot rename one to move the Vault outside the rule, while files inside those folders stay writable. The profile also denies sending Apple Events, so the Agent cannot ask another app to write for it.

Shell, web and writes outside the Vault are deliberately unrestricted, and there are no approvals or grants. An earlier design with per-action approvals and targeted grants was dropped after the feasibility investigation found that CLI grants are tool-kind-wide rather than target-specific, that CLI writes lose concurrent edits, and that shell cannot be bounded by CLI permissions, while an OS write sandbox blocks Vault writes from every tool, including shell.

This is stricter than [ADR-0002](0002-markdown-files-are-source-of-truth.md), which lets a Brain Run write `_brain/`. The Brain Run is unchanged and remains a separate operation; the App Sandbox stays off ([ADR-0004](0004-no-app-sandbox.md)) and the Seatbelt profile covers only the spawned CLI process tree. The deprecation risk of `sandbox-exec` is accepted; the fallback is a VM or container with a read-only Vault mount.

## Persistence and lifecycle

History is stored outside the Vault, separately for each Vault, and can be reopened and continued after a restart. Switching Vaults or quitting stops active work while preserving history, and nothing from the previous Vault enters another Vault's conversation.

History lives in `~/Library/Application Support/Notess/BrainConversations/<hash of the Vault path>.json`, apart from the Brain Run success record. The file is versioned and holds a list of conversations with the id of the current one, so several conversations per Vault need no new format; today one is read and written. Unknown fields are ignored and missing optional ones get defaults, so records written by older or newer builds of the activity list still load. A file from a newer format version, for another Vault or malformed is reported in the panel and is never read as empty or overwritten; asking is unavailable until the user chooses to start a new conversation, which moves the old file aside. A save failure is shown in the panel. Streaming turns are saved at most every half second, so a crash keeps most of a partial answer.

The transcript is what the user sees; the Agent's context lives in its ACP session, whose id is stored with the conversation. After a restart the next question starts a new `copilot --acp` process under the same Vault write sandbox, with the same launch checks as the first start, and loads that session with `session/load`. The history the CLI replays while loading is discarded, so nothing is duplicated, and no earlier prompt is resubmitted. The conversation instructions are sent again only to a session that never received them. If the session cannot be loaded (the CLI lacks `session/load`, or no longer knows the session), the turn fails with an explicit message and the history stays; the user can retry or choose to continue without earlier context, which discards the stored session id and opens a new one. A turn that was running when Notess ended is restored as incomplete with the reason „přerušena“, together with the partial answer.

At most one Agent operation, either a Brain Run or a conversation turn, owns a Vault at a time. The Vault stays owned until cancellation and the cleanup of the processes the operation owns have finished, so repeated cancellation, Vault changes and quit cannot release it early, and late events from a stopped operation are ignored. Both operation kinds share this ownership and cleanup, but not a transport or a success record: a Brain Run is completion-oriented, a conversation turn streams over ACP.

Notes stay viewable and editable during a turn; the next message is submitted only after the turn finishes or is stopped. There is no fixed step limit. The panel shows activity, elapsed time and Stop; stopped output is marked incomplete and failures are reported explicitly.

## Considered options

Extending Brain Run would mix incremental note processing with conversation. An external terminal would not give the in-app evidence experience. Approval-gated writes were considered and rejected as above; any future Agent writes need a separate decision.
