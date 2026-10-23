# AGENTS.md

## Agent skills

### Issue tracker

Issues are tracked in GitHub Issues for `michalmar/notess` (via the `gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one root `GLOSSARY.md` plus `docs/adr/`. See `docs/agents/domain.md`.

## Build and test

Swift package, macOS 15+, no Xcode project. Run from the repo root:

- `swift build`: build everything.
- `swift test`: run all unit tests (Swift Testing). `swift test --filter NotessCoreTests` for the core only.
- `scripts/build-app.sh`: build and sign `build/Notess.app` (App Sandbox off, ADR 0004).

Module boundaries (see `README.md`): `NotessCore` holds domain logic and must not import AppKit/SwiftUI; `NotessEditor` holds the TextKit 2 editor; `Notess` is the SwiftUI app shell. Put new domain logic in `NotessCore` with tests. In the editor never read `NSTextView.layoutManager`: it silently switches the view to TextKit 1.

## Testing

- While developing, run only the suites relevant to the feature: `swift test --filter <Suite>`.
- Before a PR: full `swift test`, then `NOTESS_HOSTED_UI=1 swift test --no-parallel --filter 'GlobalSearchPresentationTests|BrainConversationPanelTests'` once (hosted suites must not run in parallel with each other), then the gated real-CLI tests once (`NOTESS_REAL_COPILOT=1 swift test --filter RealCopilot`; launches must pass `--disable-mcp-server workiq-mail`).
- Don't re-investigate failures that also fail on `main`; file an issue and disable the test with `.disabled` plus `.bug(<issue url>)`.
- Env flags: `NOTESS_HOSTED_UI` (hosted-window UI suites in `NotessTests`, run serialized), `NOTESS_REAL_COPILOT` (real Copilot CLI), `NOTESS_REAL_BROWSER` (real web link opener), `NOTESS_SEARCH_LATENCY` (full search latency run).
