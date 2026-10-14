# Notess

A native macOS Markdown journal: every day gets one **Daily Entry** in a user-chosen **Vault**, and an Agent later distils the notes into a linked "second brain". Terminology is defined in [`GLOSSARY.md`](GLOSSARY.md); architecture decisions are in [`docs/adr/`](docs/adr/).

## Requirements

- macOS 15 or later
- Xcode 16+ command-line tools (Swift 6 toolchain)

## Build, test and run

Everything is a Swift package and runs from the command line; no Xcode project is needed.

| Task | Command |
| --- | --- |
| Build (debug) | `swift build` (or `make build`) |
| Run unit tests | `swift test` (or `make test`) |
| Build `build/Notess.app` | `scripts/build-app.sh` (or `make app`) |
| Build and open the app | `make run` |
| Clean | `make clean` |

`scripts/build-app.sh [debug|release]` wraps the `Notess` executable into an app bundle using [`Support/Info.plist`](Support/Info.plist) and signs it with [`Support/Notess.entitlements`](Support/Notess.entitlements), which disables App Sandbox (ADR 0004). It signs ad-hoc by default; set `CODESIGN_IDENTITY="Developer ID Application: …"` to sign for distribution (hardened runtime is enabled automatically).

`swift run Notess` also works for quick iteration, but the bundled app is what users run.

## Project structure

```
Package.swift
Sources/
  NotessCore/     Domain logic, no UI: Vault, settings, Copilot CLI detection, DailyEntry
  NotessEditor/   The editor: AppKit NSTextView on TextKit 2, wrapped for SwiftUI
  Notess/         SwiftUI app shell: window, Vault selection, tabs and menu commands
Tests/
  NotessCoreTests/    Unit tests for the domain logic
  NotessEditorTests/  Tests for the editor view configuration (e.g. TextKit 2)
Support/          Info.plist and entitlements for the .app bundle
scripts/          build-app.sh
```

Dependencies point inwards: `Notess` → `NotessEditor`, `NotessCore`. `NotessCore` must not import AppKit or SwiftUI so it stays fast to test; `NotessEditor` does not depend on `NotessCore`.

## Behaviour

- Open **Notess → Nastavení…** (`Cmd+,`) to change the Vault, editor font and its size, or Copilot CLI path. A Vault change asks whether to save or discard unsaved text before opening the new Vault. The editor settings persist in `UserDefaults` and apply immediately. Notess always follows the macOS light/dark appearance.
- Copilot CLI is autodetected from standard Homebrew, npm and user-local locations, then from the login shell's `PATH`. A manual path overrides autodetection; missing executables are shown as an error.
- On launch today's Daily Entry is open. If `Journal/YYYY/MM/YYYY-MM-DD.md` does not exist yet, the editor starts with `# YYYY-MM-DD` and nothing is written to disk until **Cmd+S** (ADR 0003).
- Notes open in tabs with one tab per file; reopening a file selects its existing tab. **Cmd+T** opens today's Daily Entry, **Cmd+S** saves the active tab and **Cmd+W** closes it.
- Unsaved tabs have a dot. Closing an unsaved tab asks whether to save it; quitting with any unsaved tabs asks once whether to save all, discard all or cancel.
- Open tabs, their order and the active tab are restored after restart. Missing files are skipped except for today's not-yet-saved Daily Entry.
