# Notess: Preserve pasted hyperlinks

## project

Notess

## owner: @michalmar

## date: 2026-11-02

## description: Preserve hyperlink text and destinations as Markdown when pasting rich text.

### Status

User-approved feature specification. This document describes intended behavior,
not an implemented feature. Related issue: [#130](https://github.com/michalmar/notess/issues/130).

### Problem

Copying text containing hyperlinks from an email and pasting it into Notess loses
the underlying destination URLs. The visible text survives, but users must
recreate the Markdown links manually.

Preserve those destinations without turning Notess into a rich-text editor or
introducing a general HTML-to-Markdown importer.

### Terminology

- **External link**: a link to a web address or email destination, distinct from
  a Wiki-link to another note in the Vault.
- **Visible text**: the copied text displayed to the reader for a link.
- **Destination URL**: the underlying address associated with that text.

These terms do not change the existing Wiki-link or Citation semantics.

### Ordinary paste

Ordinary paste (Cmd+V) preserves every supported hyperlink when the clipboard
provides both visible text and its destination. This applies to a single copied
link and to larger selections containing surrounding text, paragraphs, and
multiple links.

For example, copying "See documentation and pricing." with separate underlying
URLs for "documentation" and "pricing" produces:

```markdown
See [documentation](https://example.com/docs) and [pricing](https://example.com/pricing).
```

Preserve surrounding text, order, and paragraph boundaries. Do not convert bold,
italics, colors, table structure, or other rich formatting into Markdown.
Existing text-paste behavior remains the baseline outside link preservation.

### Supported destinations

- Preserve valid absolute `http:`, `https:`, and `mailto:` destinations.
- For unsupported or invalid destinations, retain only the visible text.
- Do not infer missing destinations, resolve relative URLs against a guessed
  base, fetch URLs, or open links during paste.
- If a web link's visible text is exactly identical to its destination URL,
  insert the bare URL rather than a redundant Markdown wrapper.
- If a visible URL differs from its destination, preserve both through
  `[visible URL](actual destination)`.
- Escape Markdown syntax as needed so the inserted link retains its intended
  visible text and destination.

### Plain-text paste and existing behavior

Paste and Match Style / paste without formatting (Option+Shift+Cmd+V) inserts
plain visible text without creating Markdown links.

A clipboard containing only plain text is unchanged, including bare URLs and
existing Markdown source. Missing hidden destinations cannot be recovered or
guessed.

Paste replaces the current selection in the usual way. Pasting a URL over
selected text does not introduce a new "wrap selection in a link" behavior.
Preserve normal editability restrictions and the editor's existing undo behavior.

Existing image-only paste and text-plus-image behavior must remain unchanged.

### Source applications

Use the available clipboard content rather than identifying a particular source
application. Email clients, browsers, and document editors are in scope when they
provide visible text and destination metadata. Plain-text-only clipboard content
is insufficient to reconstruct hidden URLs.

### Acceptance criteria

- [ ] Copying a named web hyperlink and using ordinary paste inserts
  `[name](https://example.com)`.
- [ ] A selection containing multiple links and paragraphs preserves every
  supported destination, surrounding text, order, and paragraph boundaries.
- [ ] A valid email hyperlink becomes, for example,
  `[Email us](mailto:hello@example.com)`.
- [ ] A web link displayed as exactly its destination remains a bare URL.
- [ ] A link whose visible URL and destination differ retains both in Markdown.
- [ ] Unsupported schemes, including `file:` and `javascript:`, and invalid
  destinations retain only the visible text.
- [ ] Markdown metacharacters in labels and syntax-sensitive characters in
  destinations produce valid links with the intended label and target.
- [ ] Paste without formatting inserts visible text only, even when richer
  link metadata is available.
- [ ] Plain text, bare URLs, and existing Markdown source are not reinterpreted
  or double-wrapped.
- [ ] Rich-text styles other than links do not introduce new Markdown formatting.
- [ ] Pasting over a selection performs ordinary replacement, not
  selection-to-link wrapping; undo restores the prior content using the editor's
  normal grouping.
- [ ] Image-only and text-plus-image paste behavior remains unchanged.
- [ ] The conversion works across source applications providing supported
  clipboard representations, without application-specific detection.
- [ ] Plain-text-only sources retain existing behavior without guessed URLs.

### Implementation context

The following are observed integration points, not a prescribed implementation:

- `Sources/NotessEditor/MarkdownEditor.swift` configures a plain-text Markdown
  editor with `isRichText = false`. Preserve that model.
- `Sources/NotessEditor/MarkdownTextView.swift` owns the custom `paste(_:)` and
  pasteboard-reading path. Its current custom interception handles image-only
  content; other paste operations are delegated to AppKit.
- `Tests/NotessEditorTests/MarkdownTextViewPasteTests.swift` covers image paste
  and text/image precedence and is the existing paste regression-test surface.
- `Tests/NotessEditorTests/MarkdownTextViewLinkTests.swift` covers interaction
  with already-inserted links, not rich clipboard conversion.

Keep domain-only conversion logic, if extracted, in `NotessCore` without
AppKit/SwiftUI imports. Clipboard/AppKit integration belongs in `NotessEditor`.
Never access `NSTextView.layoutManager`; preserve TextKit 2.

The exact HTML, RTF, or other representations supplied by source applications,
their precedence, and AppKit's current handling have not been verified. Inspect
representative clipboard payloads during implementation and cover supported
representations with deterministic fixtures. Do not assume one email client's
payload represents all sources. Verify that the plain-text paste command routes
separately from ordinary paste.

### Validation expectations

Add focused regression tests for the acceptance criteria, including rich
clipboard fixtures, mixed links/text, supported and unsupported targets, Markdown
escaping, missing metadata, and the explicit plain-text paste path.

Manually exercise copying from an email and another rich-text source, recording
the source applications and clipboard representations actually verified. Follow
the repository's targeted-test workflow during development and required checks
before a subsequent PR.

### Out of scope

- General HTML/RTF-to-Markdown conversion or preservation of all source formatting.
- New link-opening behavior, URL fetching, attachment importing, or new URL schemes.
- Wiki-link conversion, automatic linking of plain text, or URL-to-selection wrapping.
- Implementation of the feature as part of this documentation task.
