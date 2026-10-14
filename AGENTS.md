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
