# Notess

A native macOS note-taking app centred on a dated journal of plain Markdown files, with an LLM agent that distils those notes into a linked "second brain".

## Language

### Notes

**Vault**:
The single user-chosen folder that holds all notes as plain Markdown files; the app's entire world.
_Avoid_: Workspace, library, notebook

**Journal**:
The dated part of the Vault, holding all Daily Entries organised by year and month.
_Avoid_: Diary, timeline, calendar

**Daily Entry**:
The one note per calendar day, in which everything written that day lives.
_Avoid_: Daily note, journal file, day file

**Free Note**:
A note the user creates in any folder of the Vault outside the Journal; it is not tied to a single day.
_Avoid_: Page, document

**Section**:
The span of a note from one second-level heading to the next; the unit that search returns, Tags apply to, and Brain Notes cite.
_Avoid_: Block, chunk, topic, chapter

**Tag**:
A `#word` token (hash immediately followed by a word, no space) written anywhere in a note; it marks the whole Section it appears in.
_Avoid_: Label, category, topic

### Second brain

**Brain Note**:
A note written and maintained solely by the Agent, capturing facts about one Entity distilled from the user's notes.
_Avoid_: Wiki page, summary, knowledge note

**Citation**:
The link from a fact in a Brain Note back to the Section it was derived from; a fact without a Citation does not exist.
_Avoid_: Source, reference, backlink

**Entity**:
A real-world thing the second brain tracks (by default a person, company, project or place); each Entity has exactly one Brain Note.
_Avoid_: Object, item, subject

**Brain Run**:
One execution of the Agent over the Vault, processing every note changed since the last successful Brain Run.
_Avoid_: Sync, job, processing

**Agent**:
The LLM process that reads the user's notes and creates or updates Brain Notes.
_Avoid_: Bot, assistant, AI
