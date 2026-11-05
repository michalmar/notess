# Notess Tasks

## project

## owner: @michalmar

## date: 2026-11-04

## description: Approved specification for Markdown Tasks, manual Due Dates and a read-only Task Overview.

### Status and governing decisions

Approved design, not an implementation. This document records the agreed first
version of Tasks.

[Markdown files remain the source of truth](adr/0002-markdown-files-are-source-of-truth.md),
and [explicit saving with Cmd+S remains unchanged](adr/0003-explicit-save.md).
Continuous saving was considered and rejected. There is no separate saving
policy for Tasks.

Domain terms are defined in [GLOSSARY.md](../GLOSSARY.md): Task, Open Task,
Due Date and Task Overview.

### Task model and scope

A Task belongs to the note in which it is written, not to a separate task store
or project. It has exactly two states: open and completed.

The Task Overview includes saved Daily Entries and Free Notes throughout the
Vault, including nested folders. It excludes Brain Notes and unsaved content.
An Open Task remains open regardless of whether its Due Date is absent, today,
in the past or in the future.

Every checkbox occurrence is a separate Task. Equal text does not merge Tasks,
either within a note or across notes. Nested Tasks have independent states:
completing a parent does not complete its descendants, and completing all
descendants does not complete the parent. An open descendant of a completed
parent still appears in the Task Overview.

### Markdown contract

Keep the existing standard task-list syntax. Supported list markers are `-`,
`*`, `+` and numbered lists. `[ ]` means open; `[x]` and `[X]` mean completed.
Bare `[ ]` in prose, or on a line without a list marker, does not acquire new
Task semantics. Code examples are not Tasks.

A Due Date is written manually in the Task's text as `📅 YYYY-MM-DD`, for example:

```markdown
## Schůzka s ACME

- [ ] Poslat nabídku 📅 2026-11-06
- [x] Ověřit kontakty
- [ ] Připravit podklady
  - [ ] Poslat klientovi 📅 2026-11-09
```

The Markdown text is authoritative. Rendering a checkbox or date chip must not
rewrite the note. Adding, changing or removing a Due Date is a manual text edit;
there is no calendar picker or separate metadata editor.

### Source context

Every Task Overview row shows the Task text and its source context: the Daily
Entry date or Free Note name, the containing heading path, and any enclosing
Tasks. Without a heading, the note itself provides the context.

For example, two occurrences of `Poslat nabídku` remain distinguishable through
their source notes and headings. A nested `Poslat klientovi` also shows its
parent `Připravit podklady`. Keep source-note identity unambiguous when different
folders contain notes with the same name.

Heading context follows the containing heading hierarchy; it is not limited to
the second-level Sections used by search. This does not change the existing
meaning of Section, Tag or Tag Timeline.

### Navigation and overview layout

Add a third sidebar mode, **Úkoly**, alongside **Journal** and **Tagy**. In this
mode, the sidebar contains filters and the main content area contains the large
Task Overview. The sidebar is not the Task list.

The filters are:

| UI label | Content |
|---|---|
| Všechny nesplněné | All Open Tasks; the default filter. |
| Po termínu | Open Tasks whose valid Due Date is before the current local day. |
| Dnes | Open Tasks due on the current local day. |
| Nadcházející | Open Tasks due after the current local day, without a fixed future cutoff. |
| Bez termínu | Open Tasks without a valid Due Date, including invalid dates with a visible warning. |
| Splněné | Completed Tasks, which remain in their source notes. |

The default overview groups Open Tasks in this order: **Po termínu**, **Dnes**,
**Nadcházející**, **Bez termínu**. Dated Tasks are ordered by Due Date ascending.
For equal dates and undated Tasks, order Daily Entries newest first and Free
Notes by name; preserve source-text order for Tasks from the same note.
Completed Tasks are not classified as overdue.

The entire overview is read-only. Its status indicators do not toggle Tasks,
and its dates do not open editing controls. Completion, reopening, Due Date
changes, text edits, movement and deletion all happen in the source note.

### Due Date semantics and errors

A Due Date is an optional calendar date, not a time, start date, reminder or
instruction to hide a Task until that day. A Task due on 6 November becomes
overdue on 7 November according to the current local calendar day. Classification
must remain correct when the local day changes.

The stored form is the unambiguous date `YYYY-MM-DD`. Display may use a compact,
localized date, but the original date remains available in the source text.
There are no times, notifications or recurring Tasks in this version.

Do not silently correct, clamp or guess invalid dates. For an impossible date
such as `📅 2026-02-31`, or conflicting Due Dates on one Task, keep the Task in
the overview without assigning a valid Due Date and show **Neplatný termín**.
An open Task with this error appears under **Bez termínu**. Keep the invalid
source text unchanged rather than presenting it as a valid date chip.

### Source-editor presentation

In the editable source note, render Task markers as clickable checkboxes that
remain visible while typing. Completed Task text remains struck through.
Toggling a checkbox changes the source Markdown and is undoable.

Outside the currently edited line, show a valid Due Date as a compact date chip.
When editing the line, make the original `📅 YYYY-MM-DD` text available for manual
editing. The chip is a presentation of text, not a calendar control.

Checkbox and text edits follow ordinary note editing, Undo and Cmd+S. Rendering
must preserve surrounding Task text and unrelated Markdown. Existing read-only
note presentations must remain read-only.

### Saved-content contract

The overview reflects only successfully saved content. A new unsaved Task does
not appear, and an unsaved change to an existing Task's text, state or Due Date
does not alter its overview row. After a successful Cmd+S, refresh the overview
from the saved note.

Saved changes made outside Notess must also update the overview through the
normal external-file-change handling. A removed saved Task must not remain as a
stale row. Save failures must not be presented as successful persistence, and
existing external-change conflict handling must not be bypassed.

There are no pending edits owned by the overview, no overview-specific save
button and no autosave exception.

### Opening the source and returning

Clicking a Task opens its source note at that exact occurrence and makes the
target visible. Reuse an existing open tab rather than creating a second
editable copy or replacing its unsaved text.

The overview may describe an older saved version while the open note has
unsaved edits. If the target cannot be located unambiguously in that current
content, open the source note with a visible warning instead of jumping to an
unrelated occurrence. Equal Task text alone is not sufficient to choose a target.

Returning to the Task Overview preserves the selected filter and list scroll
position. There is no side-by-side source preview in this version.

### Explicit non-goals

This version does not introduce standalone Tasks, separate project assignments,
additional Task states, automatic parent-child completion, times, reminders or
recurrence. It does not introduce a calendar picker, editing in the overview,
continuous note saving or an alternative save workflow.

### Acceptance scenarios

These are requirements for a future implementation, not a record of executed
tests.

| Scenario | Expected result |
|---|---|
| Saved Tasks occur in a Daily Entry, a nested Free Note and a Brain Note. | Include the first two, exclude the Brain Note. |
| A supported list uses `[ ]`, `[x]` or `[X]`; similar text appears in prose or code. | Recognize the standard Tasks without treating prose or code as Tasks. |
| A Task is added or changed without Cmd+S. | The overview retains the saved state; successful saving updates it. |
| A saved note is changed externally, or a saved Task is removed. | Refresh from persisted content without stale or duplicate rows. |
| An open Task is overdue, due today, due later or undated. | Place it in the correct filter and group using the current local day. |
| A Due Date contains an impossible date or conflicting dates. | Retain the Task with a visible error; do not invent a valid date. |
| Two Tasks have the same text. | Keep separate rows with distinguishable source context and correct targets. |
| A parent is completed while a child remains open. | The child remains open and visible, with its parent as context. |
| A user clicks a Task in the overview. | Open the exact source occurrence; do not change its state or date. |
| The source is already open with unsaved edits. | Reuse that tab and preserve its text; warn if the target is ambiguous. |
| The user returns from a source note to the overview. | Restore the selected filter and scroll position. |
| A source checkbox is toggled and then undone. | Restore the original Markdown; neither operation saves before Cmd+S. |
| A Task line enters or leaves editing. | Switch date presentation without changing the saved Markdown or checkbox availability. |
| A Task is completed and saved. | Remove it from open filters, retain it in the source and show it under Splněné. |
