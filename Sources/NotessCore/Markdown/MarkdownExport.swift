import Foundation

/// Renders the selected part of a note as portable formatted content: HTML for
/// rich-text recipients and readable plain text for the same selection.
///
/// The whole note is lexed, so the selection keeps the formatting it has in
/// context (a word inside `**bold**` stays bold, lines inside a code fence stay
/// code) while no unselected visible text is included. Markdown syntax, YAML
/// front matter and editor decorations are left out. Block wrappers such as a
/// list item or table may be generated around selected text; a selection
/// within a single line that does not cover all of it stays an inline fragment.
public enum MarkdownExport {
    public struct Output: Equatable, Sendable {
        public var html: String
        public var plainText: String
        /// True when the selection contains nothing a recipient would see.
        public var isEmpty: Bool

        public init(html: String, plainText: String, isEmpty: Bool) {
            self.html = html
            self.plainText = plainText
            self.isEmpty = isEmpty
        }
    }

    /// A selected image stored with the note rather than on the web.
    public struct LocalImage: Equatable, Sendable {
        /// The image's source as written in the Markdown.
        public var source: String
        /// Its readable description, used in plain text.
        public var description: String
    }

    /// Renders `selection` of `text`.
    ///
    /// - Parameter embedLocalImage: Returns the HTML `src` that embeds a selected
    ///   local image, or throws when it cannot be exported; the error is
    ///   rethrown and nothing is rendered. Remote images never reach it: they
    ///   become descriptions and are neither fetched nor referenced.
    public static func render(
        _ text: String,
        selection: NSRange,
        embedLocalImage: (LocalImage) throws -> String
    ) throws -> Output {
        try withoutActuallyEscaping(embedLocalImage) { embed in
            try Renderer(text: text as NSString, embedLocalImage: embed).render(selection)
        }
    }

    /// Readable text for an image: its alternative text, or a generic label.
    static func imageDescription(alt: String) -> String {
        alt.isEmpty ? "[Obrázek]" : "[Obrázek: \(alt)]"
    }

    /// Whether an image source is on the web (or protocol-relative), as
    /// opposed to stored with the note.
    static func isRemoteImage(_ source: String) -> Bool {
        if source.hasPrefix("//") { return true }
        guard let colon = source.firstIndex(of: ":") else { return false }
        let scheme = source[..<colon].lowercased()
        return scheme == "http" || scheme == "https"
    }

    /// An ordinary web or email destination a recipient can open, or nil.
    static func clickableDestination(_ source: String, isAutolink: Bool) -> String? {
        let lower = source.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: source), url.host != nil else { return nil }
            return source
        }
        if lower.hasPrefix("www.") { return "http://" + source }
        if lower.hasPrefix("mailto:") { return source.count > 7 ? source : nil }
        if isAutolink, !source.contains(":"), source.contains("@") { return "mailto:" + source }
        return nil
    }
}

// MARK: - Model

private struct Run: Equatable {
    struct Style: Equatable {
        var isStrong = false
        var isEmphasis = false
        var isStrikethrough = false
        var isCode = false
        var link: String?
    }

    enum Content: Equatable {
        case text(String)
        case image(src: String, description: String)
    }

    var content: Content
    var style: Style

    var plainText: String {
        switch content {
        case .text(let text): text
        case .image(_, let description): description
        }
    }
}

private enum ListMarker: Equatable {
    case bullet
    case number(Int)
}

private enum LineKind {
    case heading(Int)
    case paragraph
    case listItem(level: Int, marker: ListMarker, task: Bool?)
    case listContinuation(level: Int)
    case code
    case tableRow(isHeader: Bool)
    case rule
    case blank
}

private struct Line {
    var kind: LineKind
    var quoteDepth = 0
    /// Inline content; for a table row, one entry per cell.
    var cells: [[Run]]
    /// Raw text of a code line.
    var code: String

    var runs: [Run] { cells.first ?? [] }
}

// MARK: - Renderer

private struct Renderer {
    let text: NSString
    let embedLocalImage: (MarkdownExport.LocalImage) throws -> String

    /// One line of the note as the lexer sees it.
    private struct Lexed {
        var range: NSRange
        var quoteDepth: Int
        /// Including the line break.
        var fullRange: NSRange
        var state: MarkdownLineState
        var next: MarkdownLineState
        var tokens: [MarkdownToken]
        var tableRow: MarkdownTable.Row?
        var listLine: MarkdownListLine?
        var isFirst: Bool
    }

    func render(_ requested: NSRange) throws -> MarkdownExport.Output {
        let lower = max(0, min(requested.location, text.length))
        let upper = max(lower, min(requested.upperBound, text.length))
        let selection = NSRange(location: lower, length: upper - lower)
        guard selection.length > 0 else { return .init(html: "", plainText: "", isEmpty: true) }

        let touched = lexLines(through: selection.upperBound).filter {
            NSIntersectionRange($0.fullRange, selection).length > 0
        }
        var lines: [Line] = []
        var inlineFragment = false
        let candidates = touched.filter { kind(of: $0) != nil }
        if candidates.count == 1, let only = candidates.first, let kind = kind(of: only),
           !covers(selection, contentOf: only, kind: kind) {
            inlineFragment = true
        }
        for lexed in candidates {
            guard let kind = kind(of: lexed) else { continue }
            var rendered = try line(lexed, kind: kind, selection: selection)
            rendered.quoteDepth = lexed.quoteDepth
            lines.append(rendered)
        }
        return inlineFragment ? renderInline(lines.first) : renderBlocks(lines)
    }

    // MARK: Lexing

    private func lexLines(through end: Int) -> [Lexed] {
        var starts = [0]
        for index in 0..<text.length where text.character(at: index) == Char.lf {
            starts.append(index + 1)
        }
        func units(_ line: Int) -> [UInt16] {
            let start = starts[line]
            var stop = line + 1 < starts.count ? starts[line + 1] - 1 : text.length
            if stop > start && text.character(at: stop - 1) == Char.cr { stop -= 1 }
            guard stop > start else { return [] }
            var buffer = [UInt16](repeating: 0, count: stop - start)
            text.getCharacters(&buffer, range: NSRange(location: start, length: stop - start))
            return buffer
        }
        var result: [Lexed] = []
        var states = [MarkdownLineState.documentStart]
        for line in starts.indices {
            guard starts[line] <= end || line == 0 else { break }
            let lineUnits = units(line)
            let prefix = quotePrefix(in: lineUnits, states: states)
            let contentStart = starts[line] + prefix.length
            let state = prefix.depth < states.count ? states[prefix.depth] : MarkdownLineState()
            var lexer = MarkdownLineLexer(
                line: Array(lineUnits.dropFirst(prefix.length)), offset: contentStart, recognizesLinkedImages: true
            )
            let next = lexer.lex(state: state, isFirstLine: line == 0 && prefix.depth == 0) {
                guard line + 1 < starts.count else { return nil }
                let following = units(line + 1)
                let nextPrefix = quotePrefix(in: following, states: states)
                guard nextPrefix.depth == prefix.depth else { return nil }
                return Array(following.dropFirst(nextPrefix.length))
            }
            let fullEnd = line + 1 < starts.count ? starts[line + 1] : text.length
            result.append(Lexed(
                range: NSRange(location: contentStart, length: lineUnits.count - prefix.length),
                quoteDepth: prefix.depth,
                fullRange: NSRange(location: starts[line], length: fullEnd - starts[line]),
                state: state,
                next: next,
                tokens: lexer.tokens,
                tableRow: lexer.tableRow,
                listLine: lexer.listLine,
                isFirst: line == 0
            ))
            states = Array(repeating: MarkdownLineState(followsBlankLine: false, allowsIndentedCode: false), count: prefix.depth)
                + [next]
        }
        return result
    }

    /// Keep a separate block context inside each quote, preserving indentation
    /// for nested lists and treating `>` inside fenced code as literal text.
    private func quotePrefix(in units: [UInt16], states: [MarkdownLineState]) -> (depth: Int, length: Int) {
        var depth = 0
        var end = 0
        while end < units.count {
            if depth < states.count, states[depth].fence != nil || states[depth].isFrontMatter { break }
            var marker = end
            while marker < units.count && marker - end < 3 && units[marker] == Char.space { marker += 1 }
            guard marker < units.count, units[marker] == Char.gt else { break }
            end = marker + 1
            if end < units.count && Char.isWhitespace(units[end]) { end += 1 }
            depth += 1
        }
        return (depth, end)
    }

    /// The line's block meaning, or nil for lines that are only syntax or
    /// metadata (front matter, fences, table delimiter rows, setext underlines).
    private func kind(of line: Lexed) -> LineKind? {
        let kinds = line.tokens.map(\.kind)
        if line.state.isFrontMatter || kinds.contains(.frontMatter) { return nil }
        if line.state.fence != nil {
            return kinds.contains(.syntaxMarker) && !kinds.contains(.codeBlock) ? nil : .code
        }
        if line.next.fence != nil { return nil }
        if kinds.contains(.codeBlock) { return .code }
        if line.state.isSetextUnderline { return nil }
        if let row = line.tableRow {
            return row.kind == .delimiter ? nil : .tableRow(isHeader: row.kind == .header)
        }
        for kind in kinds {
            if case .heading(let level) = kind { return .heading(level) }
        }
        if kinds.contains(.thematicBreak) { return .rule }
        if let listLine = line.listLine {
            switch listLine.marker {
            case nil:
                return .listContinuation(level: listLine.level)
            case .some(let marker):
                let task = line.tokens.lazy.compactMap { token -> Bool? in
                    if case .task(let isChecked) = token.kind { isChecked } else { nil }
                }.first
                if case .number(let number) = marker {
                    return .listItem(level: listLine.level, marker: .number(number), task: task)
                }
                return .listItem(level: listLine.level, marker: .bullet, task: task)
            }
        }
        if contentRange(of: line, kind: .paragraph).length == 0 { return .blank }
        return .paragraph
    }

    /// The visible content of a line, after its block markers and before
    /// trailing whitespace. Code keeps all of its characters but the
    /// indentation that makes it an indented code block.
    private func contentRange(of line: Lexed, kind: LineKind) -> NSRange {
        var start = line.range.location
        var end = line.range.upperBound
        switch kind {
        case .code:
            if line.state.fence == nil {
                var columns = 0
                while start < end && columns < 4 {
                    let unit = text.character(at: start)
                    guard unit == Char.space || unit == Char.tab else { break }
                    columns += unit == Char.tab ? 4 - columns % 4 : 1
                    start += 1
                }
            }
            return NSRange(location: start, length: end - start)
        case .listItem:
            start = line.listLine?.contentStart ?? start
        case .heading:
            // Leading heading markers and the whitespace after them.
            var advanced = true
            while advanced {
                advanced = false
                while start < end && Char.isWhitespace(text.character(at: start)) { start += 1 }
                for token in line.tokens where token.range.location == start && token.range.length > 0 {
                    switch token.kind {
                    case .syntaxMarker where !isInlineMarker(token, in: line), .listMarker:
                        start = token.range.upperBound
                        advanced = true
                    default:
                        break
                    }
                }
            }
        default:
            break
        }
        // A task box belongs to the item's marker.
        for token in line.tokens {
            if case .task = token.kind, token.range.location >= start, token.range.location <= start + 1 {
                start = token.range.upperBound
            }
        }
        while start < end && Char.isWhitespace(text.character(at: start)) { start += 1 }
        while end > start && Char.isWhitespace(text.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// A syntax marker that belongs to inline formatting (emphasis, code,
    /// links) rather than to the line's block marker.
    private func isInlineMarker(_ marker: MarkdownToken, in line: Lexed) -> Bool {
        line.tokens.contains { token in
            switch token.kind {
            case .strong, .emphasis, .strikethrough, .inlineCode, .link, .wikiLink, .image:
                return NSLocationInRange(marker.range.location, token.range)
                    || token.range.location == marker.range.upperBound
                    || marker.range.upperBound == token.range.location
            default:
                return false
            }
        }
    }

    private func covers(_ selection: NSRange, contentOf line: Lexed, kind: LineKind) -> Bool {
        let content = contentRange(of: line, kind: kind)
        return selection.location <= content.location && selection.upperBound >= content.upperBound
    }

    private func line(_ lexed: Lexed, kind: LineKind, selection: NSRange) throws -> Line {
        switch kind {
        case .code:
            let content = contentRange(of: lexed, kind: kind)
            let range = NSIntersectionRange(content, selection)
            let code = range.length > 0 || content.length == 0 ? text.substring(with: range) : ""
            return Line(kind: kind, cells: [], code: code)
        case .tableRow:
            var cells: [[Run]] = []
            for cell in lexed.tableRow?.cells ?? [] {
                cells.append(try runs(in: trimmed(cell), of: lexed, selection: selection))
            }
            return Line(kind: kind, cells: cells, code: "")
        case .blank, .rule:
            return Line(kind: kind, cells: [], code: "")
        default:
            let content = contentRange(of: lexed, kind: kind)
            return Line(kind: kind, cells: [try runs(in: content, of: lexed, selection: selection)], code: "")
        }
    }

    private func trimmed(_ range: NSRange) -> NSRange {
        var start = range.location
        var end = range.upperBound
        while start < end && Char.isWhitespace(text.character(at: start)) { start += 1 }
        while end > start && Char.isWhitespace(text.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    // MARK: Inline content

    /// The selected part of `content` as styled runs: syntax markers and link
    /// destinations are dropped, every character keeps the formatting of the
    /// spans around it in the whole note.
    private func runs(in content: NSRange, of line: Lexed, selection: NSRange) throws -> [Run] {
        let range = NSIntersectionRange(content, selection)
        guard range.length > 0 else { return [] }
        let tokens = line.tokens
        var runs: [Run] = []
        var pending: [UInt16] = []
        var pendingStyle = Run.Style()
        func flush() {
            guard !pending.isEmpty else { return }
            runs.append(Run(content: .text(String(decoding: pending, as: UTF16.self)), style: pendingStyle))
            pending.removeAll()
        }
        func append(_ units: [UInt16], style: Run.Style) {
            if style != pendingStyle { flush() }
            pendingStyle = style
            pending.append(contentsOf: units)
        }

        var index = range.location
        while index < range.upperBound {
            if let image = tokens.first(where: { $0.isImage && NSLocationInRange(index, $0.range) }) {
                flush()
                if case .image(let source) = image.kind {
                    runs.append(try imageRun(image, source: source, tokens: tokens, style: style(at: image.range.location, in: tokens)))
                }
                index = image.range.upperBound
                continue
            }
            if let destination = tokens.first(where: { $0.kind == .linkDestination && NSLocationInRange(index, $0.range) }) {
                index = destination.range.upperBound
                continue
            }
            if tokens.contains(where: { $0.kind == .syntaxMarker && NSLocationInRange(index, $0.range) }) {
                index += 1
                continue
            }
            let unit = text.character(at: index)
            if unit == Char.hash, let wikiLink = tokens.first(where: { $0.kind == .wikiLink && NSLocationInRange(index, $0.range) }) {
                // `[[Project#Next steps]]` reads "Project - Next steps"; `[[#Heading]]` reads "Heading".
                let isFirstHash = !(text.substring(with: NSRange(location: wikiLink.range.location, length: index - wikiLink.range.location)).contains("#"))
                if isFirstHash {
                    let target = text.substring(with: NSRange(location: wikiLink.range.location + 2, length: index - wikiLink.range.location - 2))
                    if !target.trimmingCharacters(in: .whitespaces).isEmpty {
                        append(Array(" - ".utf16), style: style(at: index, in: tokens))
                    }
                    index += 1
                    continue
                }
            }
            append([unit], style: style(at: index, in: tokens))
            index += 1
        }
        flush()
        return runs
    }

    private func style(at index: Int, in tokens: [MarkdownToken]) -> Run.Style {
        var style = Run.Style()
        for token in tokens where NSLocationInRange(index, token.range) {
            switch token.kind {
            case .strong: style.isStrong = true
            case .emphasis: style.isEmphasis = true
            case .strikethrough: style.isStrikethrough = true
            case .inlineCode: style.isCode = true
            case .link:
                if !tokens.contains(where: {
                    $0.isImage && token.range.location > $0.range.location
                        && token.range.upperBound < $0.range.upperBound
                }) {
                    style.link = destination(of: token, in: tokens)
                }
            default: break
            }
        }
        return style
    }

    /// Where a link token leads, when that is an ordinary web or email address.
    private func destination(of link: MarkdownToken, in tokens: [MarkdownToken]) -> String? {
        let after = link.range.upperBound
        if after + 2 <= text.length,
           text.substring(with: NSRange(location: after, length: 2)) == "](",
           let token = tokens.first(where: { $0.kind == .linkDestination && $0.range.location == after + 2 }) {
            let value = Array(text.substring(with: token.range).utf16)
            guard let parsed = MarkdownLinkDestination.parse(value, from: 0, to: value.count) else { return nil }
            return MarkdownExport.clickableDestination(unescaped(parsed.source), isAutolink: false)
        }
        let isAutolink = link.range.location > 0 && text.character(at: link.range.location - 1) == Char.lt
        return MarkdownExport.clickableDestination(text.substring(with: link.range), isAutolink: isAutolink)
    }

    private func imageRun(_ image: MarkdownToken, source: String, tokens: [MarkdownToken], style: Run.Style) throws -> Run {
        let altRange = tokens.first {
            $0.kind == .link && $0.range.location > image.range.location
                && $0.range.upperBound < image.range.upperBound
        }?.range
        let alt = altRange.map { visibleText(in: $0, tokens: tokens) } ?? ""
        let description = MarkdownExport.imageDescription(alt: alt)
        if MarkdownExport.isRemoteImage(source) {
            return Run(content: .text(description), style: style)
        }
        let src = try embedLocalImage(MarkdownExport.LocalImage(source: source, description: description))
        return Run(content: .image(src: src, description: description), style: style)
    }

    private func visibleText(in range: NSRange, tokens: [MarkdownToken]) -> String {
        var units: [UInt16] = []
        for index in range.location..<range.upperBound
        where !tokens.contains(where: { $0.kind == .syntaxMarker && NSLocationInRange(index, $0.range) }) {
            units.append(text.character(at: index))
        }
        return String(decoding: units, as: UTF16.self).trimmingCharacters(in: .whitespaces)
    }

    private func unescaped(_ source: String) -> String {
        var result = ""
        var escaping = false
        for character in source {
            if !escaping && character == "\\" {
                escaping = true
                continue
            }
            escaping = false
            result.append(character)
        }
        return result
    }

    // MARK: Output

    private func renderInline(_ line: Line?) -> MarkdownExport.Output {
        guard let line else { return .init(html: "", plainText: "", isEmpty: true) }
        var html = ""
        let plain: String
        switch line.kind {
        case .code:
            html = "<code style=\"\(Style.code)\">\(escape(line.code))</code>"
            plain = line.code
        default:
            let runs = line.cells.flatMap { $0 }
            html = HTML.inline(runs)
            plain = runs.map(\.plainText).joined()
        }
        let isEmpty = plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return .init(html: HTML.document(html), plainText: plain, isEmpty: isEmpty)
    }

    private func renderBlocks(_ lines: [Line], wrappingDocument: Bool = true) -> MarkdownExport.Output {
        var html = ""
        var plain: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.quoteDepth > 0 {
                var group: [Line] = []
                while index < lines.count && lines[index].quoteDepth > 0 {
                    var quoted = lines[index]
                    quoted.quoteDepth -= 1
                    group.append(quoted)
                    index += 1
                }
                let quote = renderBlocks(group, wrappingDocument: false)
                html += "<blockquote style=\"\(Style.quote)\">\(quote.html)</blockquote>"
                plain += quote.plainText.components(separatedBy: "\n").map { "    " + $0 }
                continue
            }
            switch line.kind {
            case .heading(let level):
                html += "<h\(level)>\(HTML.inline(line.runs))</h\(level)>"
                plain.append(Plain.text(line.runs))
                index += 1
            case .rule:
                html += "<hr>"
                plain.append("———")
                index += 1
            case .blank:
                plain.append("")
                index += 1
            case .paragraph:
                let group = take(lines, from: &index) { if case .paragraph = $0 { true } else { false } }
                html += "<p>" + group.map { HTML.inline($0.runs) }.joined(separator: "<br>") + "</p>"
                plain += group.map { Plain.text($0.runs) }
            case .code:
                let group = take(lines, from: &index) { if case .code = $0 { true } else { false } }
                let code = group.map(\.code).joined(separator: "\n")
                html += "<pre style=\"\(Style.pre)\"><code style=\"\(Style.code)\">\(escape(code))</code></pre>"
                plain += group.map(\.code)
            case .tableRow:
                let group = take(lines, from: &index) { if case .tableRow = $0 { true } else { false } }
                html += HTML.table(group)
                plain += group.map { row in row.cells.map(Plain.text).joined(separator: "\t") }
            case .listItem, .listContinuation:
                let group = takeList(lines, from: &index)
                html += HTML.list(group)
                plain += Plain.list(group)
            }
        }
        while plain.last == "" { plain.removeLast() }
        while plain.first == "" { plain.removeFirst() }
        let text = plain.joined(separator: "\n")
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !lines.contains { line in line.cells.joined().contains { if case .image = $0.content { true } else { false } } }
        return .init(html: wrappingDocument ? HTML.document(html) : html, plainText: text, isEmpty: isEmpty)
    }

    private func take(_ lines: [Line], from index: inout Int, while matches: (LineKind) -> Bool) -> [Line] {
        var group: [Line] = []
        while index < lines.count && lines[index].quoteDepth == 0 && matches(lines[index].kind) {
            group.append(lines[index])
            index += 1
        }
        return group
    }

    /// List lines, including blank lines between items of the same list.
    private func takeList(_ lines: [Line], from index: inout Int) -> [Line] {
        var group: [Line] = []
        while index < lines.count && lines[index].quoteDepth == 0 {
            switch lines[index].kind {
            case .listItem, .listContinuation:
                group.append(lines[index])
                index += 1
            case .blank:
                var next = index
                while next < lines.count, lines[next].quoteDepth == 0, case .blank = lines[next].kind { next += 1 }
                guard next < lines.count, lines[next].quoteDepth == 0 else { return group }
                switch lines[next].kind {
                case .listItem, .listContinuation: index = next
                default: return group
                }
            default:
                return group
            }
        }
        return group
    }
}

private extension MarkdownToken {
    var isImage: Bool {
        if case .image = kind { true } else { false }
    }
}

// MARK: - Serialisation

private enum Style {
    static let code = "font-family: Menlo, Monaco, Consolas, monospace; white-space: pre-wrap;"
    static let pre = "white-space: pre-wrap;"
    static let quote = "margin: 0 0 0 0.8em; padding-left: 0.8em; border-left: 3px solid #c8c8c8;"
    static let table = "border-collapse: collapse;"
    static let cell = "border: 1px solid #c8c8c8; padding: 4px 8px; text-align: left;"
}

private func escape(_ text: String) -> String {
    var result = ""
    result.reserveCapacity(text.utf8.count)
    for character in text {
        switch character {
        case "&": result += "&amp;"
        case "<": result += "&lt;"
        case ">": result += "&gt;"
        case "\"": result += "&quot;"
        default: result.append(character)
        }
    }
    return result
}

private enum HTML {
    static func document(_ body: String) -> String {
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>\(body)</body></html>"
    }

    static func inline(_ runs: [Run]) -> String {
        runs.map { run in
            var html: String
            switch run.content {
            case .text(let text):
                html = escape(text)
            case .image(let src, let description):
                html = "<img src=\"\(escape(src))\" alt=\"\(escape(description))\">"
            }
            if run.style.isCode { html = "<code style=\"\(Style.code)\">\(html)</code>" }
            if run.style.isStrikethrough { html = "<s>\(html)</s>" }
            if run.style.isEmphasis { html = "<em>\(html)</em>" }
            if run.style.isStrong { html = "<strong>\(html)</strong>" }
            if let link = run.style.link { html = "<a href=\"\(escape(link))\">\(html)</a>" }
            return html
        }.joined()
    }

    static func taskMarker(_ isChecked: Bool?) -> String {
        switch isChecked {
        case .some(true): "☑ "
        case .some(false): "☐ "
        case nil: ""
        }
    }

    static func table(_ rows: [Line]) -> String {
        var html = "<table style=\"\(Style.table)\">"
        let header = rows.prefix { if case .tableRow(true) = $0.kind { true } else { false } }
        if !header.isEmpty {
            html += "<thead>" + header.map { row(of: $0, cell: "th") }.joined() + "</thead>"
        }
        let body = rows.dropFirst(header.count)
        if !body.isEmpty {
            html += "<tbody>" + body.map { row(of: $0, cell: "td") }.joined() + "</tbody>"
        }
        return html + "</table>"
    }

    private static func row(of line: Line, cell: String) -> String {
        "<tr>" + line.cells.map { "<\(cell) style=\"\(Style.cell)\">\(inline($0))</\(cell)>" }.joined() + "</tr>"
    }

    /// Nested lists, relative to the shallowest selected level.
    static func list(_ lines: [Line]) -> String {
        let base = lines.compactMap(\.listLevel).min() ?? 0
        var html = ""
        var stack: [(isOrdered: Bool, hasOpenItem: Bool)] = []
        func closeTop() {
            guard let top = stack.popLast() else { return }
            if top.hasOpenItem { html += "</li>" }
            html += top.isOrdered ? "</ol>" : "</ul>"
        }
        for line in lines {
            switch line.kind {
            case .listItem(let level, let marker, let task):
                let depth = level - base + 1
                var isOrdered = false
                var start = 1
                if case .number(let number) = marker {
                    isOrdered = true
                    start = number
                }
                while stack.count > depth { closeTop() }
                if stack.count == depth {
                    if stack[depth - 1].isOrdered != isOrdered {
                        closeTop()
                    } else if stack[depth - 1].hasOpenItem {
                        html += "</li>"
                        stack[depth - 1].hasOpenItem = false
                    }
                }
                while stack.count < depth {
                    if let last = stack.indices.last, !stack[last].hasOpenItem {
                        html += "<li>"
                        stack[last].hasOpenItem = true
                    }
                    let opensOrdered = stack.count == depth - 1 && isOrdered
                    html += opensOrdered ? (start == 1 ? "<ol>" : "<ol start=\"\(start)\">") : (stack.count == depth - 1 ? "<ul>" : "<ul>")
                    stack.append((opensOrdered, false))
                }
                html += "<li>" + taskMarker(task) + inline(line.runs)
                stack[depth - 1].hasOpenItem = true
            case .listContinuation:
                if stack.isEmpty {
                    html += "<p>" + inline(line.runs) + "</p>"
                } else {
                    html += "<br>" + inline(line.runs)
                }
            default:
                break
            }
        }
        while !stack.isEmpty { closeTop() }
        return html
    }
}

private enum Plain {
    static func text(_ runs: [Run]) -> String {
        runs.map(\.plainText).joined()
    }

    static func list(_ lines: [Line]) -> [String] {
        let base = lines.compactMap(\.listLevel).min() ?? 0
        return lines.map { line in
            switch line.kind {
            case .listItem(let level, let marker, let task):
                let indent = String(repeating: "    ", count: max(0, level - base))
                let bullet = switch marker {
                case .bullet: "• "
                case .number(let number): "\(number). "
                }
                return indent + bullet + HTML.taskMarker(task) + text(line.runs)
            case .listContinuation(let level):
                return String(repeating: "    ", count: max(0, level - base)) + "  " + text(line.runs)
            default:
                return ""
            }
        }
    }
}

private extension Line {
    var listLevel: Int? {
        switch kind {
        case .listItem(let level, _, _), .listContinuation(let level): level
        default: nil
        }
    }
}
