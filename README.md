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
  NotessCore/     Domain logic, no UI: Vault, VaultWatcher (FSEvents), settings, Copilot CLI detection, DailyEntry,
                  Markdown/ (incremental MarkdownLexer, Tag, WikiLink),
                  WikiLinkResolver (link target → note), NoteSection (heading lookup),
                  Search/ (Section splitting, SQLite FTS5 SearchIndex, SearchQuery)
  NotessEditor/   The editor: AppKit NSTextView on TextKit 2 with live Markdown formatting, wrapped for SwiftUI
  Notess/         SwiftUI app shell: window, Vault selection, tabs and menu commands
Tests/
  NotessCoreTests/    Unit tests for the domain logic
  NotessEditorTests/  Tests for the editor view (TextKit 2, formatting, tasks)
Support/          Info.plist and entitlements for the .app bundle
scripts/          build-app.sh
```

Dependencies point inwards: `Notess` → `NotessEditor` → `NotessCore`. `NotessCore` must not import AppKit or SwiftUI so it stays fast to test; Markdown parsing (formatting, Tags, wiki-links) lives there so search and backlinks can reuse it, while `NotessEditor` only turns tokens into fonts and colours.

## Behaviour

- Open **Notess → Nastavení…** (`Cmd+,`) to change the Vault, editor font and its size, or Copilot CLI path. A Vault change asks whether to save or discard unsaved text before opening the new Vault. The editor settings persist in `UserDefaults` and apply immediately. Notess always follows the macOS light/dark appearance.
- Copilot CLI is autodetected from standard Homebrew, npm and user-local locations, then from the login shell's `PATH`. A manual path overrides autodetection; missing executables are shown as an error.
- On launch today's Daily Entry is open. If `Journal/YYYY/MM/YYYY-MM-DD.md` does not exist yet, the editor starts with `# YYYY-MM-DD` and nothing is written to disk until **Cmd+S** (ADR 0003).
- Notes open in tabs with one tab per file; reopening a file selects its existing tab. **Cmd+T** opens today's Daily Entry, **Cmd+S** saves the active tab and **Cmd+W** closes it.
- Unsaved tabs have a dot. Closing an unsaved tab asks whether to save it; quitting with any unsaved tabs asks once whether to save all, discard all or cancel.
- The Vault is watched with FSEvents (`VaultWatcher` in `NotessCore`), so files changed outside Notess (git, other editors, the Agent) show up right away: the sidebar refreshes, a tab without unsaved changes reloads silently, and a tab with unsaved changes shows a „Načíst / Ponechat moje“ bar. „Načíst“ discards the local edits; „Ponechat moje“ hides the bar and the next Cmd+S overwrites the file. A file deleted outside Notess keeps its text in the tab, which is struck through, counts as unsaved (closing or quitting asks first) and shows a bar to save it again or close it. Changes are detected by comparing content, so the app's own Cmd+S never triggers the bar, and Cmd+S never silently overwrites a file changed on disk in the meantime.
- Open tabs, their order and the active tab are restored after restart. Missing files are skipped except for today's not-yet-saved Daily Entry.
- The editor formats Markdown live (GFM headings, emphasis, strikethrough, code, quotes, lists, tables, links, `[[wiki-links]]` incl. `[[note#Section]]`, `#tags`). The markup stays visible, only dimmed. Clicking a task box `[ ]`/`[x]` toggles it like an edit (undoable, unsaved until Cmd+S). Only the edited lines are restyled while typing. Headings and code scale with the editor font from Settings; fonts and colours are a `MarkdownEditorStyle` built by `MarkdownEditor`.
- Clicking a `[[wiki-link]]` (or Cmd-click) opens the note in a tab, or selects its existing tab; `[[note#Section]]` also scrolls to that heading (case-insensitive). Targets are matched by file name anywhere in the Vault (Journal, Free Notes, `_brain/`), ignoring case and `.md`; `[[Folder/Note]]` narrows to a folder. Duplicate names resolve deterministically (`WikiLinkResolver`): exact-case match, then Free Note over Daily Entry over Brain Note, then fewest folders, then alphabetical path. A missing note or Section shows a message and writes nothing.
- **Cmd+Shift+F** searches the text of all notes and shows matching Sections (the text under a `##` heading; the text before the first `##` counts as one more) grouped Journal / Notes / Brain, ranked by relevance with the matched words highlighted. Search ignores case and diacritics and matches word prefixes; `#tag` words filter to Sections that carry the Tag (`#tag` alone lists them, newest Daily Entry first). Arrow keys pick a result, Enter or a click opens the note in a tab scrolled to the Section. The index is a SQLite FTS5 cache outside the Vault (`~/Library/Caches/Notess/SearchIndex/`), updated in the background on launch, on Cmd+S, on outside changes and when the app becomes active; **Přegenerovat index hledání** in the File menu rebuilds it from the files.
- Pasting an image inserts `![](attachments/…)` and previews it inline below the still-visible Markdown. Image bytes are staged with the note and written to an `attachments/` folder beside it only on **Cmd+S**, including for a not-yet-saved Daily Entry.
