# Global search performance

Spec #75 sets one responsiveness target for global search (Cmd+Shift+F), verified by #83:

> On a Vault of 10,000 files whose search index is already built, the first visible results appear within **500 ms of the last keystroke** on the developer's Mac, and typing stays responsive while indexing runs.

This document explains what counts as the target, how it is measured and how to reproduce the measurement.

## What counts

- **Measured end to end through the app.** The clock starts when the last key event is sent to the focused query field (or the All / Journal / Notes / Brain control is clicked). It stops when the result list shows rows for that query. The span includes the 120 ms debounce, the `SearchIndex` query, one result per file, previews with highlights, and SwiftUI list layout. The time of the query alone is reported too, but only to help diagnose problems.
- **Warm index.** Initial indexing of a new Vault is excluded and reported on its own line. The search overlay still shows results while indexing runs, and a line under them says they may be incomplete. Background work on a built index still counts: a search typed right after app activation (the catch-up scan) or right after Cmd+S must meet the target too.
- **Typing stays responsive.** A main-thread heartbeat records the longest stall while searches run and while the whole index is rebuilt in the background. A stall must stay under 100 ms. The status line must be shown at every keystroke made while indexing.

## The test Vault

`Tests/NotessTests/RepresentativeVault.swift` writes a deterministic Vault (seed 83) into a temporary folder. The real Vault is never used.

- 7,000 Daily Entries (`Journal/YYYY/MM/YYYY-MM-DD.md`), 2,500 Free Notes and 500 Brain Notes, about 25 MB in total.
- Czech text with diacritics, several `##` Sections per note, and the Tags `#projekt` and `#projekty`, which share a prefix.
- Common words in many Sections (`kickoff`, `klient`, `rozpočet`) and one rare word (`zřídkavý`, in 7 files).

## Workload

Each search is typed key by key into the hosted app five times. The worst run must stay within 500 ms.

| Search | Typed | Gap between keys |
|---|---|---|
| common word, slow typing | `kickoff` | 150 ms (a search runs for almost every prefix) |
| common word, fast typing | `kickoff` | 60 ms |
| two words in one Section | `klient rozpočet` | 150 ms |
| short prefix, very many Sections | `ro` | 150 ms |
| diacritics-insensitive | `rozpocet` | 100 ms |
| rare word | `zřídkavý` | 150 ms |
| Tag only | `#projekt` | 150 ms |
| Tag and word | `#projekt kickoff` | 150 ms |
| right after app activation (the catch-up scan of the whole Vault is running) | `kickoff` | 60 ms |
| right after Cmd+S on the open note (it is indexed again) | `kickoff` | 60 ms |
| one letter right after app activation | `k` | – |
| scope clicks | Journal, Notes, Brain, All with `kickoff` typed | – |

Finally, `kickoff klient` is typed during a full background rebuild of the index, to check typing responsiveness and the indexing status.

## Reproduce

From the repository root, on a Mac with nothing heavy running:

```sh
scripts/measure-search-latency.sh            # debug build, as `swift test` uses
scripts/measure-search-latency.sh release    # optimised build, closer to the shipped app
```

The script runs the opt-in test `SearchLatencyTests/tenThousandFiles` with `NOTESS_SEARCH_LATENCY=1`. The app is hosted inside the test process, so a running Notess is not touched. A run takes about five minutes. The script prints a Markdown report with the machine details and writes it to `build/search-latency-<configuration>.md` (or to the path given as the second argument). The test fails if any search exceeds 500 ms, if typing stalls longer than 100 ms, or if the indexing status is missing.

A 200-file version of the same measurement always runs in `swift test` (`SearchLatencyTests/smallMeasurement`), so the harness can't break unnoticed. Its timings don't count as evidence.

## What made it fast

The first measurement (debug build) missed the target: `klient rozpočet` took 14.2 s, slowly typed `kickoff` 5.3 s and `ro` 6.9 s. Profiling the index with the `sqlite3` CLI found two causes:

1. **Short prefixes were expensive.** A query of one or two letters (`k`, `ro`) merges the posting lists of every word with that prefix. The preview query (`highlight`/`snippet` for the 50 shown files) did that merge again for every file in its `rowid IN (…)` list: 0.6–1.8 s per note kind. Slow typing queued one such search per prefix on the `SearchIndex` actor, and the last keystroke waited behind them.
2. **Superseded searches could not stop.** `GlobalSearch` cancelled its task, but the SQLite statement kept running.

The fixes in `SearchIndex` (the first one raises the schema version to 5):

- The FTS5 table has `prefix = '1 2 3'` indexes, so prefix queries of one to three characters read one precomputed list. The `ro` preview went from 570 ms to about 1 ms. The cost: the cache grows by about 28 MB for 10,000 files (FTS data about 48 MB instead of 20 MB). Existing caches are discarded and rebuilt once on the next launch, because the schema version changed.
- `search` runs inside `SQLiteDatabase.cancellable(when:)`. A SQLite progress handler checks `Task.isCancelled`, so a search superseded by a newer keystroke stops within milliseconds.
- The preview query filters with `+rowid IN (…)`. The unary `+` makes FTS5 run the MATCH once and filter the rows, instead of once per listed file. That cut previews for two-word queries from about 90 ms to 6 ms per note kind.
- The catch-up scan (on app activation, on outside changes) lists the Vault's files off the actor. For 10,000 files the listing takes about half a second, and a search typed meanwhile used to wait for it: one letter typed right after activation took 638 ms. A note that is missing from the listing is removed from the index only if it is still gone afterwards, so a note saved during the scan stays indexed.

## Results

Apple M2 Pro (12 cores, 32 GB), macOS 27.0.1 (26A434), Low Power Mode off. Median and worst of five runs each, in ms. Initial indexing of the 10,000 files took 19.5 s in the debug build and 11.9 s in the release build. A full rebuild with search open took 17.8 s and 10.9 s. A catch-up scan with nothing changed took 507 ms and 438 ms. None of these count towards the target.

| Search | Results (files) | Debug median | Debug worst | Release median | Release worst | Release query only |
|---|---:|---:|---:|---:|---:|---:|
| common word, slow typing: kickoff | 150 | 272 | 283 | 271 | 278 | 59 |
| common word, fast typing: kickoff | 150 | 278 | 282 | 260 | 275 | 59 |
| two words in one Section: klient rozpočet | 150 | 295 | 296 | 291 | 292 | 80 |
| short prefix, very many Sections: ro | 150 | 309 | 309 | 305 | 305 | 95 |
| diacritics-insensitive: rozpocet | 150 | 298 | 307 | 290 | 291 | 76 |
| rare word: zřídkavý | 7 | 151 | 154 | 150 | 152 | 2 |
| Tag only: #projekt | 100 | 228 | 229 | 220 | 223 | 18 |
| Tag and word: #projekt kickoff | 100 | 250 | 252 | 249 | 251 | 36 |
| right after app activation: kickoff | 150 | 194 | 204 | 246 | 248 | 64 |
| one letter right after app activation: k | 150 | 314 | 317 | 302 | 304 | 114 |
| right after Cmd+S: kickoff | 150 | 277 | 280 | 273 | 277 | 58 |
| scope journal clicked: kickoff | 50 | 83 | 84 | 80 | 81 | 30 |
| scope notes clicked: kickoff | 50 | 71 | 72 | 69 | 71 | 20 |
| scope brain clicked: kickoff | 50 | 67 | 70 | 65 | 67 | 17 |
| scope all clicked: kickoff | 150 | 119 | 122 | 118 | 122 | 59 |

Debug: over 430 keystrokes during searches, the worst key handling took 5 ms and the worst main-thread stall was 52 ms. During the background rebuild, the worst stall was 36 ms. Release: 7 ms, 50 ms and 40 ms. Both builds showed the indexing status at 14 of 14 keystrokes made while indexing.

Of each typed search, about 120 ms is the deliberate debounce and up to about 115 ms is the query. The rest is preparing and laying out the result list. The slowest case, one letter right after app activation, leaves about 180 ms of headroom.
