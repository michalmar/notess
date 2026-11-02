# Rich link paste (HTML)

Ticket #131, first slice of spec #130. Cmd+V keeps hyperlinks from an HTML clipboard as Markdown links.

## Design

- `RichTextLinkMarkdown` (`NotessCore`) turns `[Segment]` (`.text` / `.link(label:destination:)`) into Markdown. It is source-agnostic so another rich-text source (RTF, #132) can feed it.
- `ClipboardHTML` (`NotessEditor`) is a tolerant, dependency-free HTML scanner producing those segments. It deliberately avoids `NSAttributedString` HTML import (WebKit, run-loop spinning, possible remote fetches). Nothing is fetched or opened on paste.
- `MarkdownTextView.paste` intercepts only when the HTML contains at least one link that renders as `[label](destination)`. Otherwise the previous behaviour runs unchanged (plain text preferred, image paste, AppKit fallback).
- `pasteAsPlainText:` (Paste and Match Style) never converts links: it pastes the pasteboard string, or the HTML's visible text when there is no string.

## Link semantics

- Destinations: absolute `http`/`https` with a host, and `mailto:` with an address. Relative URLs, `javascript:`, `file:` and others are not links; their label stays plain text.
- A web link whose label equals its destination stays a bare URL. Empty labels are dropped.
- Labels have Markdown metacharacters escaped; text outside labels is never escaped. Spaces and unbalanced parentheses in destinations are percent-encoded.
- `<p>`/headings/lists/tables give a blank line, `<div>`/`<li>`/`<br>` a single newline, table cells a space. Other formatting adds no Markdown.
- Encodings: UTF-8/16 (with or without BOM), the declared charset, then Windows-1252.

## Observed clipboards

- **Chromium / Teams "copy link"** (real clipboard): `public.html`, `public.utf8-plain-text`, `org.chromium.internal.source-rfh-token`, `org.chromium.source-url`. HTML: `<meta charset='utf-8'><div itemprop="teams-copy-link"><a href="…">label</a></div>`, `&amp;` in hrefs.
- **WebKit** (a real `WKWebView` select-all + copy, the serializer used by Safari and Mail): `com.apple.webarchive`, `public.rtf`, `public.html`, `public.utf8-plain-text`, `public.utf16-external-plain-text`, `com.apple.WebKit.custom-pasteboard-data`. HTML: `<meta charset="UTF-8">` then one `<p style="…">` per paragraph, `<span class="Apple-converted-space"> </span>` for spaces next to links. `javascript:` hrefs were dropped by WebKit; `file:` and `mailto:` were kept.

The user's clipboard was snapshotted and restored around the probes.

## Limitations

- Safari and Mail were not driven through their GUI (scripted copy did not work), so WebKit stands in for them. Outlook and other Office apps were not probed; the Outlook-style test fixture is synthetic.
- RTF is offered by WebKit but not handled here (#132).
- Paste and Match Style against the real general pasteboard is covered by a test, but should be checked manually in the app.
