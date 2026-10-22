# Note organization, navigation, and search

Status: design confirmed on 2026-10-21; not implemented by this document.

This document records the agreed scope for editor links and spacing, Tag
Groups, file deletion, and local and global search. It is a target behavior
specification, not a description of functionality already shipped.

## Current behavior and terminology

Use the terms in [GLOSSARY.md](../GLOSSARY.md). In particular, a Daily Entry
belongs to the Journal, a Free Note belongs to Notes, and a Brain Note is
maintained by the Agent.

The existing global search uses SQLite FTS5 and saved-file indexing
(`Sources/NotessCore/Search/SearchIndex.swift`,
`Sources/Notess/AppModel+Search.swift`). Its current shortcut is
Command+Shift+F, and its results are Sections. The design retains the existing
search backend while changing its presentation and accessibility.

The Tag Timeline currently uses saved Daily Entries only. Daily Entries can
also exist as unsaved, in-memory documents with no file on disk. These
distinctions remain intentional.

## Editor links

- Recognize bare `http://` and `https://` URLs and Markdown web links such as
  `[label](https://example.com)`.
- Exclude inline code and fenced code blocks from link activation.
- Command+click opens the URL in the system's default browser.
- An ordinary click in an editable note continues to place the text cursor.
- Preserve the existing behavior of `[[Wiki-links]]`.
- Automatic recognition of addresses without a scheme, such as
  `www.example.com`, is outside this scope.

The reported failure to activate links is a behavior to reproduce and resolve;
this design does not assume a verified implementation-level cause.

## Heading spacing

Add half of a normal body-text line above and below each heading, H1 through
H6, relative to the existing spacing. Both additions scale with the current
editor font size and text zoom.

This is visual formatting only: do not insert blank lines into Markdown,
change note content, or introduce a spacing preference.

## Tag Groups

A Tag Group organizes sidebar Tags, not note files or note content.

- Support one level of named, collapsible groups, without nested groups.
- Allow creating a group while the sidebar is showing Tags.
- Provide a Tag context-menu action to add it to an existing or new group.
- A Tag can belong to multiple groups; adding it does not remove other
  memberships.
- Keep an All Tags list independent of group membership.
- Grouping does not expand the Tag Timeline's source scope: sidebar Tags
  continue to come only from saved Daily Entries in the Journal.
- Clicking a grouped Tag retains the existing Tag Timeline behavior.
- Removing a membership affects only that membership.
- Deleting a group affects only the group and its memberships, never Tags,
  note text, or files.
- Persist groups, membership, and collapsed state per Vault on this Mac.
  Transferring or synchronizing this organization with Vault files is outside
  scope.
- If the last saved occurrence of a Tag disappears, hide that Tag but retain
  its group memberships. Restore its appearance in those groups if it
  reappears.
- Keep empty groups visible and usable.

## File deletion

Provide Delete in the sidebar context menu for individual saved Daily Entries
and Free Notes. Move the selected file to the system Trash after confirmation;
do not permanently delete it.

Brain Notes and folders are not deletable through this feature.

### Open and unsaved notes

If the selected document has unsaved changes, offer:

- Save and move to Trash.
- Discard changes and move to Trash.
- Cancel.

Saving before trashing preserves the latest edits in the recoverable file.
Discarding before trashing preserves only the previously saved version.
Cancel leaves both the document and file unchanged.

After a successful move, close the document's open tab so it cannot be
accidentally recreated by a later save. On failure, report the error rather
than treating the deletion as successful.

A Daily Entry that has never been saved has no file to move to Trash. Closing
and discarding that draft requires confirmation and must not create a file
just to trash it.

### Other notes and references

Do not rewrite other notes, remove Wiki-links or Citations, or automatically
start a Brain Run. The confirmation must warn that references to the removed
note may no longer resolve. Restoration from Trash remains possible.

## Global search: Command+Shift+F

Keep the existing search window and shortcut. On opening it, immediately focus
the search input so the user can type without another click.

Do not add a permanently visible search field to the main toolbar.

### Matching and scope

- Search saved content only; clearly indicate that limitation in the UI.
- Keep word and word-prefix matching, ignoring case and diacritics. For
  example, `rozp` matches `rozpocet`, but `poce` does not.
- Multiple ordinary search terms must match in the same Section.
- A `#tag` query filters by the exact normalized Tag, not by a substring of
  its name or an ordinary-text occurrence.
- Combining a Tag and text restricts text matching to a Section containing
  that Tag.
- Add a simple All / Journal / Notes / Brain scope selector.
- Reset the scope to All each time the search window is opened.
- Tag filtering works across those scopes, independently of the Journal-only
  sidebar Tag Timeline.
- Do not add semantic search, regular expressions, or arbitrary substring
  matching within words.

### Results

Update results as the user types. Show one result per matching file rather
than separate rows for each matching Section. Include a matching text preview.
Clicking a result opens that note at its first matching location.

Section-level matching and Tag filtering remain in effect even though the
result list is deduplicated by file.

### Responsiveness

On this Mac, with an already built index and a Vault of up to 10,000 files,
display the first results within 500 ms of the last keystroke, without blocking
typing. Measure the complete input-to-results interval, including any debounce,
not just the database query.

Initial indexing is a separate operation, excluded from that latency target,
and must have a visible status.

## In-note search: Command+F

Command+F opens a compact find bar at the current note's editor and focuses its
input. It does not invoke global search.

- Search the entire current note, including unsaved edits.
- Update and highlight matches as the user types.
- Ignore letter case.
- Enter selects the next match; Shift+Enter selects the previous match.
- Escape closes the find bar and returns focus to the editor.
- Text replacement is outside scope.

The local search and global index have deliberately different saved-content
boundaries.

## Scope boundaries

Do not include:

- Creating note folders, moving files, or renaming files.
- Deleting folders or Brain Notes.
- Nested Tag Groups.
- Expanding sidebar Tags or the Tag Timeline to Free Notes or Brain Notes.
- Synchronizing Tag Groups between devices.
- Global searching of unsaved buffers.
- Semantic search or text replacement.

## Acceptance scenarios

1. Command+click a bare HTTPS URL and a Markdown HTTPS link in an editable
   note: both open in the default browser. An ordinary click edits; equivalent
   text in code does not activate.
2. Compare H1 through H6 before and after formatting at two zoom levels:
   each has an extra half body-text line above and below, with unchanged
   Markdown content.
3. Add one Tag to two groups, collapse one, and reopen the Vault: memberships
   and collapsed state persist. All Tags still contains the Tag once.
4. Delete a group or remove one membership: the Tag and note content are
   unchanged.
5. Remove the last saved occurrence of a grouped Tag and later restore it:
   the Tag disappears and reappears with its memberships intact; empty groups
   remain available.
6. Delete a saved Daily Entry or Free Note: confirmation precedes the move,
   the file is recoverable from Trash, and its open tab closes only on success.
7. Exercise save, discard, and cancel for a dirty document, and discard an
   unsaved Daily Entry: each follows the distinct behavior described above.
8. Open global search with Command+Shift+F and type immediately: input goes
   directly to the query. Reopen after using a scope filter: All is selected.
9. Match several Sections in one file: show one result with a preview and
   open the file at the first match.
10. Compare a word-prefix query, an internal substring, an exact Tag, and a
    Tag-plus-text query across each scope: matching follows the stated rules.
11. Search a freshly edited but unsaved note: global search uses the saved
    version and explains its boundary; Command+F finds the current buffer.
12. Measure global search after indexing a 10,000-file Vault on this Mac:
    first results appear within 500 ms of the last keystroke while typing
    remains responsive.
13. Use Enter, Shift+Enter, and Escape in local search: navigate matches in
    each direction, then close the bar and restore editor focus.
