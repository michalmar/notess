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
  NotessCore/     Domain logic, no UI: Vault, Day, DailyEntry, NoteDocument, VaultLocationStore
  NotessEditor/   The editor: AppKit NSTextView on TextKit 2, wrapped for SwiftUI
  Notess/         SwiftUI app shell: window, Vault selection, menu commands (Cmd+S)
Tests/
  NotessCoreTests/    Unit tests for the domain logic
  NotessEditorTests/  Tests for the editor view configuration (e.g. TextKit 2)
Support/          Info.plist and entitlements for the .app bundle
scripts/          build-app.sh
```

Dependencies point inwards: `Notess` → `NotessEditor`, `NotessCore`. `NotessCore` must not import AppKit or SwiftUI so it stays fast to test; `NotessEditor` does not depend on `NotessCore`.

## Behaviour (v1 skeleton)

- On first launch the app asks for the Vault folder and remembers it (`UserDefaults`, key `vaultPath`). If the folder disappears it asks again. Switching the Vault in the UI comes with Settings (#13).
- On launch today's Daily Entry is open. If `Journal/YYYY/MM/YYYY-MM-DD.md` does not exist yet, the editor starts with `# YYYY-MM-DD` and nothing is written to disk until **Cmd+S** (ADR 0003).
- Cmd+S writes the file, creating `Journal/YYYY/MM/` as needed. Unsaved changes are shown by a dot in the toolbar, "Neuloženo" in the window subtitle and the standard edited dot in the close button. Quitting (or closing the window) with unsaved changes asks *Uložit změny?*; tabs and per-tab close prompts come with #3.
