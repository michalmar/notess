# Notess

A native macOS Markdown journal: every day gets one **Daily Entry** in a user-chosen **Vault**, and an Agent later distils the notes into a linked "second brain". Terminology is defined in [`GLOSSARY.md`](GLOSSARY.md); architecture decisions are in [`docs/adr/`](docs/adr/).

## Requirements

- macOS 15 or later
- Apple Silicon (M1 or later) for downloaded preview builds
- Xcode 26.3+ toolchain (Swift 6), only when building from source

## Install a preview

Download the DMG from the [main preview release](https://github.com/michalmar/notess/releases/tag/main-preview). These are development snapshots, not stable releases. Installing a preview does not require Xcode.

1. Open the downloaded `Notess-<version>-<build>-arm64.dmg`.
2. Drag **Notess** onto **Applications**. When updating, quit Notess before replacing the existing app.
3. Eject the disk image and open Notess from Applications.

**First launch:** previews are ad-hoc-signed, not signed with an Apple Developer ID or notarized by Apple. macOS may block the app because it cannot verify the developer or check it for malicious software. Only if you trust this download, try opening it, then go to **System Settings → Privacy & Security → Open Anyway** and confirm. See [Apple's guidance for apps downloaded outside the App Store](https://support.apple.com/en-us/102445). Do not disable Gatekeeper globally or override a warning that the app contains malware or has been damaged.

To update, download and install the new preview the same way; there is no in-app automatic updater. Replacing the app does not replace your Vault.

### How previews are published

The [Main preview workflow](.github/workflows/preview-release.yml) runs on every push to `main` and can also be run manually on `main`. It uses the stable macOS 26 runner with Xcode 26.6 and runs the full Swift unit test suite with `--no-parallel`, since AppKit tests share application state, plus the app manager canvas's isolated backend checks. It then builds a release-mode Apple Silicon app, verifies the signature, architecture, deployment target and disk image, and updates one rolling `main-preview` prerelease. The app still targets macOS 15+; CI checks the binary's target against `Info.plist`, but does not exercise the macOS 15 runtime. The DMG uses HFS+ for compatibility with older supported Macs.

Tests have a five-minute timeout and the job has a fifteen-minute timeout. Runs are serialized with up to 100 pending runs rather than replacing waiting pushes. The tag moves to the published commit. Failed tests or packaging leave the previous download available; runs for commits that are no longer at the tip of `main` skip publication.

The app version comes from `Support/Info.plist`. CI stamps only the packaged app's build number as `<workflow run number>.<run attempt>`; it does not commit version changes. Release notes identify the source commit, build date and DMG SHA-256. A new uniquely named DMG is uploaded before older preview DMGs are removed, so a failed upload does not delete the working download.

The workflow uses GitHub's automatic `GITHUB_TOKEN` with repository-content write permission; no Apple signing credentials are required. Stable-release automation and Developer ID signing/notarization are not configured.

## Build, test and run

Everything is a Swift package and runs from the command line; no Xcode project is needed.

| Task | Command |
| --- | --- |
| Build (debug) | `swift build` (or `make build`) |
| Run unit tests | `swift test` (or `make test`) |
| Build `build/Notess.app` | `scripts/build-app.sh` (or `make app`) |
| Build an Apple Silicon preview DMG | `scripts/build-dmg.sh` |
| Build and open the app | `make run` |
| Clean | `make clean` |

`scripts/build-app.sh [debug|release]` wraps the `Notess` executable into an app bundle using [`Support/Info.plist`](Support/Info.plist) and signs it with [`Support/Notess.entitlements`](Support/Notess.entitlements), which disables App Sandbox (ADR 0004). It signs ad-hoc by default; set `CODESIGN_IDENTITY="Developer ID Application: …"` to sign for distribution (hardened runtime is enabled automatically).

The bundle includes [`Support/AppIcon.icns`](Support/AppIcon.icns) for Finder, Dock, the app switcher and the standard About panel. The paper-and-pencil artwork is drawn by [`scripts/generate-app-icon.swift`](scripts/generate-app-icon.swift); [`Support/AppIcon.png`](Support/AppIcon.png) is its 1024-pixel preview. After changing the artwork, run `swift scripts/generate-app-icon.swift` on macOS to regenerate both assets using AppKit and Apple's `iconutil`, then commit them together with the source. Normal app and DMG builds copy the committed ICNS without regenerating it.

Set `BUILD_ARCH=arm64` or `BUILD_ARCH=x86_64` to override the host architecture, and `BUILD_NUMBER=123.1` to override the built app's `CFBundleVersion` without editing the source plist. `OUTPUT_DIR` changes the output directory (default `build/`). `scripts/build-dmg.sh` always builds `arm64` in release mode and creates `Notess-<version>-<build>-arm64.dmg` with an Applications shortcut; it accepts the same output-directory, build-number and signing-identity overrides.

`swift run Notess` also works for quick iteration, but the bundled app is what users run.

### App manager canvas

The project extension in [`.github/extensions/notess-manager/`](.github/extensions/notess-manager/) adds a **Notess app manager** canvas in Copilot. Ask Copilot to open it for this repository. It shows the installed version/build, installed source commit, and latest `origin/main` commit, with two buttons:

- **Build & install** is enabled when the app is missing, its source is untracked, or `main` has changed. Quit Notess first. It builds a clean remote snapshot with the existing build script and replaces `~/Applications/Notess.app` only after verifying the new bundle's signature and source metadata. It does not switch branches, pull into your checkout, include local edits, or change your notes.
- **Open app** launches `~/Applications/Notess.app`; it stays disabled until an app is installed and while a build is running.

Main is checked automatically every minute while the pane is open. Local build numbers advance from the installed app's build number; update detection compares commit IDs, not GitHub Actions build numbers. The source revision is embedded before signing, so tracking survives canvas reloads and new sessions. Existing copies without that metadata need one canvas build to start tracking.

Requires macOS and the Xcode toolchain above. Progress and failures appear in the pane. A per-installation lock under `$COPILOT_HOME/extensions/notess-manager/artifacts/` (default `~/.copilot/...`) prevents builds in different sessions from replacing the app concurrently. If a provider was forcibly killed, confirm no build is running before removing the lock path shown in the pane. Backend checks run with `node --test .github/extensions/notess-manager/manager.test.mjs`; they use temporary Git repositories and app bundles, not your installed app.

## Project structure

```
Package.swift
Sources/
  NotessCore/     Domain logic, no UI: Vault, VaultWatcher (FSEvents), settings, Copilot CLI detection, DailyEntry,
                  Markdown/ (incremental MarkdownLexer, Tag, WikiLink),
                  WikiLinkResolver (link target → note), NoteSection (heading lookup),
                  Search/ (Section splitting, SQLite FTS5 SearchIndex, SearchQuery, TagTimelineBrowser),
                  BrainRun/ (changed-note selection, last-run state, prompt and Copilot CLI command, process runner)
  NotessEditor/   The editor: AppKit NSTextView on TextKit 2 with live Markdown formatting, wrapped for SwiftUI
  Notess/         SwiftUI app shell: window, Vault selection, tabs and menu commands
Tests/
  NotessCoreTests/    Unit tests for the domain logic
  NotessEditorTests/  Tests for the editor view (TextKit 2, formatting, tasks)
  NotessTests/        Tests for app-level orchestration
Support/          Info.plist, entitlements and generated app icon assets for the .app bundle
scripts/          App bundle and preview DMG packaging, native app icon generator
```

Dependencies point inwards: `Notess` → `NotessEditor` → `NotessCore`. `NotessCore` must not import AppKit or SwiftUI so it stays fast to test; Markdown parsing (formatting, Tags, wiki-links) lives there so search and backlinks can reuse it, while `NotessEditor` only turns tokens into fonts and colours.

## Behaviour

- Open **Notess → Nastavení…** (`Cmd+,`) to change the Vault, editor font and its size, or Copilot CLI path. A Vault change asks whether to save or discard unsaved text before opening the new Vault. The editor settings persist in `UserDefaults` and apply immediately. Notess always follows the macOS light/dark appearance.
- **Text zoom** enlarges or shrinks the note editor's text only, without changing the Markdown, the images' display size or the rest of the app. Pinch on the trackpad over the editor (smooth), use the **−** / percentage / **+** controls in the editor toolbar (click the percentage to reset), or the **Zvětšit text** (`Cmd++`, also `Cmd+=`), **Zmenšit text** (`Cmd+-`) and **Skutečná velikost textu** (`Cmd+0`) commands in the View menu. Buttons and shortcuts change the zoom by 10 percentage points, within 50 %–300 %. The shortcuts work throughout the main note window, not in Settings or dialogs. One zoom level applies to every note and is remembered across launches; 100 % is the editor font size from Settings, and changing that font keeps the zoom. Zooming is not an edit: it does not mark the note unsaved, add an undo step or move the selection, and it keeps the text you are reading in view.
- Copilot CLI is autodetected from standard Homebrew, npm and user-local locations, then from the login shell's `PATH`. A manual path overrides autodetection; missing executables are shown as an error.
- On launch today's Daily Entry is open. If `Journal/YYYY/MM/YYYY-MM-DD.md` does not exist yet, the editor starts with `# YYYY-MM-DD` and nothing is written to disk until **Cmd+S** (ADR 0003).
- Notes open in tabs with one tab per file; reopening a file selects its existing tab before trying to read the file again, so pending edits remain available when the disk copy is unreadable or deleted. **Cmd+T** opens today's Daily Entry, **Cmd+S** saves the active tab and **Cmd+W** closes it.
- Unsaved tabs have a dot. Closing an unsaved tab asks whether to save it; quitting with any unsaved tabs asks once whether to save all, discard all or cancel.
- The Vault is watched with FSEvents (`VaultWatcher` in `NotessCore`), so files changed outside Notess (git, other editors, the Agent) show up right away: the sidebar refreshes, a tab without unsaved changes reloads silently, and a tab with unsaved changes shows a „Načíst / Ponechat moje“ bar. „Načíst“ discards the local edits; „Ponechat moje“ hides the bar and the next Cmd+S overwrites the file. A file deleted outside Notess keeps its text in the tab, which is struck through, counts as unsaved (closing or quitting asks first) and shows a bar to save it again or close it. Changes are detected by comparing content, so the app's own Cmd+S never triggers the bar, and Cmd+S never silently overwrites a file changed on disk in the meantime. Bursts of changes are coalesced (at most one pass running and one waiting) and files are read in the background, so typing is not held up; only the open notes in a changed file or folder are reread, and the app re-checks everything when it becomes active.
- Open tabs, their order and the active tab are restored after restart. Missing files are skipped except for today's not-yet-saved Daily Entry.
- The editor formats Markdown live (GFM headings, emphasis, strikethrough, code, quotes, lists, tables, links, `[[wiki-links]]` incl. `[[note#Section]]`, `#tags`). The markup stays visible, only dimmed, except in tables: they are drawn as a grid with a shaded header, the `|` pipes are hidden behind the grid lines and the `| --- |` delimiter row becomes the rule below the header, shown as text only while the caret is on it, and the text stays unchanged (typing `|` adds a column line; a table too wide for the view wraps without column lines). The cells follow the delimiter row's `:---`/`:-:`/`---:` alignment. In a table, Enter adds an empty row below (on an empty last row it leaves the table; Option+Enter breaks the line), Tab and Shift+Tab select the next and previous cell (Tab in the last cell adds a row), and the Tabulka menu and the context menu add a row below (⌘↩) or above (⇧⌘↩), a column left (⌥⌘←) or right (⌥⌘→), and delete the row (⇧⌘⌫) or the column (⌥⇧⌘⌫), each one undo step; adding or deleting a column rewrites the table's rows as `| a | b |`. Clicking a task box `[ ]`/`[x]` toggles it like an edit (undoable, unsaved until Cmd+S). Only the edited lines are restyled while typing, or the whole table when typing in one. Headings and code scale with the editor font from Settings; fonts and colours are a `MarkdownEditorStyle` built by `MarkdownEditor`.
- Clicking a `[[wiki-link]]` (or Cmd-click) opens the note in a tab, or selects its existing tab; `[[note#Section]]` also scrolls to that heading (case-insensitive). Targets are matched by file name anywhere in the Vault (Journal, Free Notes, `_brain/`), ignoring case and `.md`; `[[Folder/Note]]` narrows to a folder. Duplicate names resolve deterministically (`WikiLinkResolver`): exact-case match, then Free Note over Daily Entry over Brain Note, then fewest folders, then alphabetical path. An already-open tab remains a valid target when its disk file was deleted, using its current in-memory text; a genuinely missing unopened note or Section shows a message and writes nothing.
- **Cmd+Shift+F** searches the text of all notes and shows matching Sections (the text under a `##` heading; the text before the first `##` counts as one more) grouped Journal / Notes / Brain, ranked by relevance with the matched words highlighted. Search ignores case and diacritics and matches word prefixes; `#tag` words filter to Sections that carry the Tag (`#tag` alone lists them, newest Daily Entry first); a Tag written in a heading (`## Porada #acme`) marks its Section like one in the text, while Tags in the introduction stay local to it. Arrow keys pick a result, Enter or a click opens the note in a tab scrolled to the Section. The index is a SQLite FTS5 cache outside the Vault (`~/Library/Caches/Notess/SearchIndex/`), updated in the background on launch, on Cmd+S, on outside changes and when the app becomes active; **Přegenerovat index hledání** in the File menu rebuilds it from the files.
- **Tag completion**: typing `#` and at least one character in the editor lists the saved Tags of the whole Vault (Journal, Free and Brain Notes) that start with what you typed, sorted alphabetically, ignoring case and diacritics; an exact match is not offered. The first one is highlighted and **Tab** replaces the whole Tag at the caret with it in one undo step. **Escape**, moving the caret, clicking elsewhere, Return or Shift+Tab close the list; without a suggestion Tab keeps its usual meaning (in tables, Tab completes first and only then moves to the next cell). Suggestions come from the search index, so they reflect saved content; they are not offered in code, links, wiki-links or read-only Brain Notes.
- The **Journal / Tagy** switch at the top of the sidebar changes the window to the Tag Timeline: the sidebar lists the Tags of saved Daily Entries (normalised like search, Tags of Free and Brain Notes excluded) and selecting one shows every saved Section carrying it, complete and with the editor's formatting, grouped by Daily Entry date, newest day first and in note order within a day. It reads the search index, so it shows saved content only: unsaved text appears after Cmd+S, and outside changes after the index catches up; while indexing runs or after it failed, the list and timeline say so instead of looking empty. The timeline is read-only (task boxes do not toggle) and shows images as their Markdown for now. **Otevřít v Journalu** switches back and opens the Daily Entry in its tab, keeping unsaved text, scrolled to the Section. Switching modes keeps open tabs and never saves.
- **Cmd+V** with an image on the clipboard (e.g. a screenshot) inserts `![](attachments/image-….png)` on its own line and previews it inline below the still-visible Markdown; when the clipboard also holds text, the text is pasted. Image bytes are staged as PNG with the note and written to an `attachments/` folder beside it only on **Cmd+S**, including for a not-yet-saved Daily Entry; discarding the edit writes nothing. Clicking a staged or saved inline image opens a large aspect-ratio-preserving preview in the current window; **Escape** or **Zavřít** returns to the note without changing it.
- **Zpracovat** in the toolbar starts a Brain Run: Copilot CLI (path from Settings, else autodetected; a missing CLI shows what to do) runs in the background with the Vault as working directory, `-p` with a prompt built from `_brain/AGENTS.md`, the list of notes outside `_brain/` added, changed or deleted since the last successful run, and the run rules (recompute facts from whole files, remove facts of deleted notes, Citations, write only to `_brain/`). Only saved content counts. Copilot CLI may write only below `_brain/` (`--allow-tool write(<Vault>/_brain/**)`); `_brain/AGENTS.md`, shell and URL access are denied. The Agent cannot delete files, so it empties Brain Notes and Notess deletes empty ones after the run. The toolbar shows the status (běží / hotovo / chyba); clicking it opens the run's log (stdout and stderr). **Zrušit** terminates the CLI. The last successful run (a content fingerprint of every file outside `_brain/` when it started) is stored outside the Vault in `~/Library/Application Support/Notess/BrainRuns/` only when a run succeeds, so failed or cancelled runs process the same notes again and notes saved during a run are processed next time. Any change outside `_brain/` during a run that the user did not save in Notess stops the run and is reported as an error. A file or folder outside `_brain/` that exists but cannot be listed or read (for example, missing permissions) is never taken as deleted: it keeps Copilot CLI from starting, or stops a running Agent, and the run fails without being remembered. The editor stays usable throughout; new Brain Notes appear in the sidebar via the Vault watcher. `NOTESS_REAL_COPILOT=1 swift test --filter RealCopilotCLI` runs one Brain Run against the real CLI (costs AI credits).
