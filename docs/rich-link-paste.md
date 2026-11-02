# Rich link paste (HTML and RTF)

Tickets #131 and #132, implementing spec #130. Cmd+V keeps hyperlinks from HTML and RTF clipboards as Markdown links.

## Design

- `RichTextLinkMarkdown` (`NotessCore`) turns `[Segment]` (`.text` / `.link(label:destination:)`) into Markdown. Both clipboard readers use the same destination and escaping rules.
- `ClipboardHTML` (`NotessEditor`) is a tolerant, dependency-free HTML scanner producing those segments. It deliberately avoids `NSAttributedString` HTML import (WebKit, run-loop spinning, possible remote fetches). Nothing is fetched or opened on paste.
- `ClipboardRTF` (`NotessEditor`) uses AppKit's local RTF reader and extracts only visible text and `.link` attributes. Enumerating the link attribute, rather than all styling attributes, keeps a label split by bold/color styling as one link. The editor remains plain text and TextKit 2.
- `MarkdownTextView.paste` resolves supported rich representations completely before making one normal, undoable replacement. Rich decoding failures are logged with `NSLog`; other readable representations are still considered. If none contains readable text, paste beeps without editing. Failed rich decoding is not retried through AppKit's HTML importer.
- Plain-text-only and other existing AppKit text paste paths remain unchanged. The existing image-only attachment workflow and text-over-image-preview behavior remain intact.

## Representation precedence

Ordinary Paste selects the first usable **whole passage**, in this fixed order:

1. HTML that produces at least one supported, nonredundant Markdown link.
2. RTF that produces at least one supported, nonredundant Markdown link.
3. Nonempty plain text from the pasteboard.
4. Nonempty visible HTML text.
5. Nonempty visible RTF text.

Paste and Match Style never converts links. It selects plain text, then visible HTML text, then visible RTF text. macOS can advertise/synthesize a plain-text rendition from RTF even when the writer supplies only RTF; this rendition is eligible as plain text.

An HTML passage without usable links cannot hide usable RTF links. If HTML and RTF both contain usable links but disagree on text or destinations, HTML wins in its entirety. If neither has usable links and plain text differs, plain text wins. Clipboard type enumeration order and source application identity do not affect selection. Text or destinations from different representations are never concatenated, combined, or guessed.

## Link semantics

- Destinations: absolute `http`/`https` with a host, and `mailto:` with an address. Relative URLs, `javascript:`, `file:` and others are not links; their label stays plain text.
- A web link whose label equals its destination stays a bare URL. Empty labels are dropped.
- Labels have Markdown metacharacters escaped; text outside labels is never escaped. Spaces and unbalanced parentheses in destinations are percent-encoded.
- `<p>`/headings/lists/tables give a blank line, `<div>`/`<li>`/`<br>` a single newline, table cells a space. Other formatting adds no Markdown.
- Encodings: UTF-8/16 (with or without BOM), the declared charset, then Windows-1252.
- RTF retains its decoded line/paragraph characters without translating visual paragraph spacing into extra blank lines. Its decoded link attributes feed the same Markdown semantics as HTML; unsupported fields remain visible text.

## Observed clipboards

- **Chromium / Teams "copy link"** (real clipboard): `public.html`, `public.utf8-plain-text`, `org.chromium.internal.source-rfh-token`, `org.chromium.source-url`. HTML: `<meta charset='utf-8'><div itemprop="teams-copy-link"><a href="…">label</a></div>`, `&amp;` in hrefs.
- **WebKit** (a real `WKWebView` select-all + copy, the serializer used by Safari and Mail): `com.apple.webarchive`, `public.rtf`, `public.html`, `public.utf8-plain-text`, `public.utf16-external-plain-text`, `com.apple.WebKit.custom-pasteboard-data`. HTML: `<meta charset="UTF-8">` then one `<p style="…">` per paragraph, `<span class="Apple-converted-space"> </span>` for spaces next to links. `javascript:` hrefs were dropped by WebKit; `file:` and `mailto:` were kept.

The user's clipboard was snapshotted and restored around the probes.

### #132 GUI source probes (2026-11-02)

Both sources were opened with controlled local content (no personal message content). Select All and Copy were dispatched through each application's UI, then the actual system pasteboard was inspected. The original pasteboard's items and bytes were snapshotted before the probes, restored afterwards, and the temporary backup removed.

| Source | Supplied representations (legacy aliases omitted) | Observed content |
|---|---|---|
| Apple Mail, local `.eml` message viewer | `com.apple.webarchive`, `public.rtf`, `public.html`, `public.utf8-plain-text`, `public.utf16-external-plain-text`, Mail partial/full-document flavors, WebKit custom data | Three named links in two paragraphs; HTML `<p>` and Apple space spans; RTF nested `HYPERLINK` fields with color/underline styling. Plain text has a blank line between paragraphs; decoded RTF has one newline plus paragraph-spacing attributes. |
| Apple TextEdit, local rich-text `.rtf` document | `public.rtf`, `public.utf8-plain-text`, `public.utf16-external-plain-text` | Three named links; RTF nested `HYPERLINK` fields and backslash-newline paragraph separator. Plain text and decoded RTF have one newline. No HTML was offered. |

Both copies contained `documentation` targeting `https://example.com/docs?a=1&b=2`, `pricing` targeting `https://example.com/pricing`, and `the team` targeting `mailto:team@example.com`.

The captured RTF payloads are retained verbatim in `MarkdownTextViewPasteTests` (Mail HTML styling is trimmed in its companion fixture). Replaying them through the hosted editor's actual menu/key-equivalent commands gives:

| Clipboard selection | Ordinary Paste | Paste and Match Style |
|---|---|---|
| Mail HTML + RTF + plain text | One passage, all three Markdown links, blank line from HTML | Visible text only, blank line from the copied plain representation |
| Mail RTF + plain text, HTML removed | One passage, all three Markdown links, one RTF newline | Visible text only, blank line from the copied plain representation |
| TextEdit RTF + plain text | One passage, all three Markdown links, one newline | Visible text only, one newline |

This verifies real source serialization and editor command outcomes; it is not an end-to-end GUI paste into the installed Notess build.

## Acceptance coverage

The existing hosted "Clipboard paste" suite covers RTF-only links, shared destination/escaping behavior, multiple links and Unicode across paragraphs, style-split labels, consistent and differing representations in both type orders, malformed RTF and readable fallback, selection/caret/edit propagation, read-only restrictions, independent one-step undo/redo, and image regressions. All ordinary synthetic cases use private pasteboards.

The limited system-pasteboard test now exercises HTML, RTF, and mixed link content through command validation and dispatch for both Paste actions. Every case snapshots and restores the original clipboard, as does the existing screenshot case.

## Limitations

- The #131 WebKit probe stood in for Safari and Mail. #132 adds an actual Mail GUI copy, but Safari itself still needs manual verification.
- Mail was verified with a controlled local message, not every account/message renderer. Outlook and other Office apps were not probed; the Outlook-style HTML fixture remains synthetic. Chromium/Teams evidence remains the #131 observation, not a new #132 GUI probe.
- A final manual paste into the installed Notess app, including its Paste and Match Style menu item, remains for user verification; captured-source and system-clipboard outcomes above use the built-from-source hosted editor.
