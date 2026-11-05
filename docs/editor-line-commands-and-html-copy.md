# Notess editor line commands and Copy as HTML

## project

Notess

## owner: @michalmar

## date: 2026-11-02

## description: Agreed design for source-line movement, duplication, and portable rich copying of selected Markdown.

## Status

Design agreed through a user interview. This document describes intended
behavior, not an implemented feature. Implementation is a separate step.

## Line commands

| Command | Shortcut | Behavior |
| --- | --- | --- |
| Move Line Up | Option+Up | Swap the affected source-line group with the immediately preceding source line. |
| Move Line Down | Option+Down | Swap the affected source-line group with the immediately following source line. |
| Duplicate Line Above | Option+Shift+Up | Insert a copy of the affected source-line group immediately above it. |
| Duplicate Line Below | Option+Shift+Down | Insert a copy of the affected source-line group immediately below it. |

### Source lines and selections

- A source line ends at a newline. A visually wrapped row is not a separate
  source line, and a Markdown block can span several source lines.
- With no selection, operate on the caret's source line.
- With a selection, operate on every source line it touches, as one contiguous
  group preserving internal order.
- A selection ending exactly at the start of the next line excludes that next
  line.
- Preserve the caret's position or exact partial-text selection relative to the
  moved text. After duplication, transfer that caret or selection to the new
  copy, not the original.
- Each successful command invocation is one undoable operation. Undo/redo must
  restore both content and the associated selection.
- Blank lines participate normally.
- Moving beyond the beginning or end of the note does nothing; there is no
  wraparound. Duplication remains available at both boundaries.
- Handle a final line without a trailing newline without joining adjacent line
  contents or introducing unrelated blank lines.

These are literal source edits. Do not renumber lists, repair table structure,
rebalance code fences, change indentation, or move continuation lines that are
not part of the selected group. A heading moves as one source line, not as its
entire heading subtree or Section.

If an operation would move or duplicate hidden text in a folded heading region,
expand affected folds before applying it so the text change is visible. This
does not change the source-line unit into a heading-subtree operation.

### Availability

Expose all four commands in the Edit menu, displaying their shortcuts. Enable
them only for editable note bodies, with boundary-aware availability for moves.
They must not edit Brain Notes or other read-only views, or intercept shortcuts
in search fields and unrelated controls.

The specified Option-arrow combinations intentionally replace macOS paragraph
navigation and paragraph-selection behavior inside editable note bodies.
Unmodified arrows and other unrelated navigation remain unchanged.

## Copy as HTML

### User-facing contract

Copy as HTML copies rendered rich content, not visible HTML source code. Pasting
into a rich-text recipient such as Mail should preserve document formatting.
The clipboard also contains readable plain text for text-only recipients.
Normal Copy and Cmd+C retain their existing Markdown-copy behavior.

Expose Copy as HTML beside Copy in the Edit menu and in the context menu for
selected Markdown text. It has no new dedicated shortcut. It is available for
nonempty selections in editable notes and selectable read-only Markdown views,
including Brain Notes.

Right-clicking within selected text must preserve that selection. Never export
a stale prior selection if the normal context-menu interaction changes the
selection. With no selected text, the command is unavailable.

### Selection-aware rendering

Export only selected content, interpreting its formatting in the surrounding
note. Do not parse the selected substring in isolation or expand the selection
to full lines, paragraphs, or blocks.

For example, selecting just `hello` inside `**hello world**` exports bold
`hello`, without `world` or the Markdown markers. Similarly, selected code text
retains its code formatting even if the opening fence is outside the selection.

Structural wrappers needed for valid rich output may be included, but must not
bring unselected text into the copied content. Formatting syntax is not visible
text in the rendered export. The plain-text representation expresses the same
selected content without formatting markers.

### Portable formatting

Use semantic document formatting with neutral styling suitable for email, not a
pixel-for-pixel reproduction of the editor. The receiving app may adapt fonts,
spacing, and other presentation details.

| Markdown content | Rich clipboard representation |
| --- | --- |
| Headings | Heading structure |
| Bold, italic, strikethrough | Corresponding inline formatting |
| Ordered and unordered lists | Ordered and unordered list structure |
| Tasks | Readable checked or unchecked task markers |
| Blockquotes | Quoted content |
| Ordinary web and email links | Clickable links with their displayed text |
| Tables | Semantic tables |
| Inline and block code | Code formatting with meaningful whitespace preserved |
| Tags | Ordinary text, without editor-only interaction |
| Wiki-links | Readable labels, not local-file hyperlinks |
| YAML front matter | Omitted |
| Editor decorations and dark-mode backgrounds | Omitted |

For example, `[[Project#Next steps]]` becomes `Project - Next steps` as readable
text. Do not expose local Vault paths as recipient-facing Wiki-link targets.

### Images

- Include actual local images in the rich clipboard content, resolving their
  source relative to the note as appropriate.
- The result must be self-contained for pasting outside Notess; a local file
  path or relative HTML image URL alone does not satisfy this requirement.
- Remote images become readable descriptions. Do not fetch them or include
  remote image references that trigger loading in the recipient.
- Use image descriptions in the plain-text fallback.
- Copying must not modify the source note or its image files.
- If a selected local image is missing, unreadable, or cannot be exported,
  stop the copy, report a clear error identifying the image, and leave the
  previous clipboard contents unchanged. Do not silently downgrade that image
  to a description or partially copy the rest.

HTML is the user-facing command name, not a restriction to a single pasteboard
representation. Choose any additional native rich clipboard representation
needed for actual local-image compatibility with Mail. Successful HTML
generation alone is not evidence that image pasting works.

## Implementation foundations

Existing code offers these integration points; the rendering and rich export
implementation still needs to be designed against the behavior above:

- `Sources/NotessEditor/MarkdownTextView.swift`: responder behavior, menu
  validation, and undoable replacement helpers.
- `Sources/NotessEditor/MarkdownTextView+Tables.swift`: existing context-menu
  override that preserves standard text actions.
- `Sources/Notess/NoteCommands.swift`: app-level editing commands.
- `Sources/NotessEditor/RichClipboard.swift`, `ClipboardHTML.swift`, and
  `ClipboardRTF.swift`: existing import infrastructure, not an HTML exporter.
- `Sources/NotessCore/Markdown/MarkdownToken.swift`: supported Markdown token
  vocabulary. Live editor highlighting is not itself an HTML renderer.

Keep pure source-line transformations and reusable Markdown interpretation in
NotessCore. Keep AppKit clipboard, menu, selection, and view integration outside
NotessCore. Preserve TextKit 2; never access `NSTextView.layoutManager`.

No new domain glossary entries or ADRs are needed: these are ordinary editor
operations and reversible feature choices, not changes to Vault, Section,
Wiki-link, or Brain Note semantics.

## Acceptance criteria

1. Exercise both directions of move and duplicate with a caret, partial-line
   selection, multi-line selection, and a selection ending at the next line's
   start. Verify exact content and caret/selection results.
2. Cover wrapped lines, blank lines, Unicode text, the first and last lines,
   an empty note, and the final line with and without a trailing newline.
3. Verify repeated commands, one-step undo/redo per successful invocation,
   and boundary no-ops that do not alter content or create edits.
4. Verify literal behavior inside lists, tables, and code fences, and expansion
   of affected folds without moving a whole heading subtree.
5. Verify Edit-menu availability, shortcut routing, unchanged unrelated fields,
   and prevention of editing in read-only views.
6. Verify selection-only rich output and readable text fallback for every
   supported construct, including inline formatting and code whose delimiters
   fall outside the selected range. Exclude unselected text and front matter.
7. Verify selected-text context-menu behavior and copying from selectable
   read-only Markdown without modifying content.
8. Verify actual local images, remote-image descriptions without network
   fetching, and failure atomicity: an image export failure reports the error
   and preserves the previous clipboard.
9. Paste representative mixed content into Mail and verify actual formatting,
   links, tables, code, task markers, and local images. Paste into a text-only
   recipient and verify readable text without HTML source or raw Markdown
   formatting markers. These are future implementation checks, not claims
   that interoperability has already been verified.

## Out of scope

Automatic Markdown repair, semantic block movement, editor-appearance cloning,
remote image downloading, recipient access to Vault-local Wiki-links, a new
Copy as HTML shortcut, and any change to normal Copy.
