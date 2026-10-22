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
The span of a note from one second-level heading to the next heading of level 1 or 2; the unit that fulltext search matches and Brain Notes cite (search shows each matching note once, at its first matching Section). The text before the first second-level heading is one more, introductory Section.
_Avoid_: Block, chunk, topic, chapter

**Tag**:
A `#word` token (hash immediately followed by a word containing at least one letter) outside code, compared case-insensitively and Unicode-normalised. In the Tag Timeline it marks its nearest preceding heading, including all descendants until the next heading of equal or higher rank; text before any heading stays local, while fulltext search still filters by the Section containing the Tag.
_Avoid_: Label, category, topic

**Tag Timeline**:
For one Tag, the complete tagged heading subtrees in saved Daily Entries, grouped by date newest first and in note order within a day, without repeating descendants already included by a tagged ancestor. It is read-only and includes neither unsaved edits nor Free Notes or Brain Notes. Clicking a Tag in a note or in a Tag Timeline Section opens its Tag Timeline, like selecting the Tag in the Tags sidebar.
_Avoid_: Tag view, Tag feed, Tag page

**Tag Group**:
A flat, named collection of Tags in the Tags sidebar that only organises them: a Tag may belong to several Tag Groups and stays in All Tags, and grouping never changes notes, files or what a Tag means. Tag Groups are kept per Vault on this Mac, outside the Vault and the search index.
_Avoid_: Tag folder, parent Tag, category

**Ungrouped Tags** (UI label "Nezařazené"):
The Tags of saved Daily Entries that belong to no Tag Group, in the order of All Tags. The Tags sidebar shows them between the Tag Groups and All Tags once at least one Tag Group exists; All Tags is unchanged.
_Avoid_: Unsorted Tags, orphan Tags

**Wiki-link**:
A `[[Note]]` reference to another note by its file name, optionally to one of its headings with `[[Note#Heading]]`. The note is found by file name anywhere in the Vault, ignoring case; duplicate names resolve by the rule documented on `WikiLinkResolver`.
_Avoid_: Internal link, backlink (a backlink is a wiki-link seen from its target)

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
