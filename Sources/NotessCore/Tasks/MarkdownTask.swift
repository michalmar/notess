import CryptoKit
import Foundation

/// A Task written in Markdown: a `[ ]`, `[x]` or `[X]` box right after a list
/// marker (`-`, `*`, `+`, `1.`, `1)`), as the editor's lexer recognises it.
/// Boxes in prose, on lines without a list marker and in code are not Tasks.
public struct MarkdownTask: Hashable, Sendable {
    /// The Task's position among the note's Tasks, in source-text order.
    public let ordinal: Int
    /// The `[ ]` box, in UTF-16 offsets.
    public let boxRange: NSRange
    /// The text after the box up to the end of its line, without surrounding whitespace.
    public let text: String
    public let isCompleted: Bool
    /// The titles of the headings the Task lies under, outermost first: every
    /// level, not only the Sections of search. Empty before the first heading.
    public let headingPath: [String]
    /// The text of the Tasks whose list items contain this one, outermost
    /// first. List items without a box are skipped, not reported.
    public let enclosingTasks: [String]

    public init(
        ordinal: Int, boxRange: NSRange, text: String, isCompleted: Bool,
        headingPath: [String] = [], enclosingTasks: [String] = []
    ) {
        self.ordinal = ordinal
        self.boxRange = boxRange
        self.text = text
        self.isCompleted = isCompleted
        self.headingPath = headingPath
        self.enclosingTasks = enclosingTasks
    }

    /// Every Task of `text`, in source-text order.
    public static func tasks(in text: String) -> [MarkdownTask] {
        let string = text as NSString
        let lexer = MarkdownLexer()
        let lexed = lexer.relexAll(text: string)
        let tokens = lexed.tokens
        let headings = HeadingSection.split(text, tokens: tokens).filter { $0.headingRange != nil }
        let boxes = tokens.compactMap { token -> (range: NSRange, isChecked: Bool, text: String)? in
            guard case .task(let isChecked) = token.kind else { return nil }
            var lineEnd = 0
            var contentsEnd = 0
            string.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: token.range)
            let start = NSMaxRange(token.range)
            let line = string.substring(with: NSRange(location: start, length: max(0, contentsEnd - start)))
            return (token.range, isChecked, line.trimmingCharacters(in: .whitespaces))
        }
        let quoted = quotedListLines(tokens: tokens, in: string)
        let enclosing = enclosingTasks(
            of: boxes.map { ($0.range, $0.text) },
            listLines: (lexed.listLines + quoted.lines).sorted { $0.range.location < $1.range.location },
            startsOutsideList: Set(zip(lexer.lineStarts, lexer.states).compactMap { $1.isInList ? nil : $0 })
                .subtracting(quoted.lines.map(\.range.location))
                .union(quoted.startsOutsideList)
        )
        var result: [MarkdownTask] = []
        for (box, enclosingTasks) in zip(boxes, enclosing) {
            // A heading's subtree ends at the next heading of its level or higher,
            // so the subtrees holding the box are exactly its ancestors.
            let path = headings
                .filter { NSLocationInRange(box.range.location, $0.range) }
                .compactMap(\.title)
            result.append(MarkdownTask(
                ordinal: result.count,
                boxRange: box.range,
                text: box.text,
                isCompleted: box.isChecked,
                headingPath: path,
                enclosingTasks: enclosingTasks
            ))
        }
        return result
    }

    /// Tasks with the same text, heading path and enclosing Tasks, which
    /// only their order tells apart.
    struct Twins: Hashable {
        let text: String
        let headingPath: [String]
        let enclosingTasks: [String]
    }

    var twins: Twins { Twins(text: text, headingPath: headingPath, enclosingTasks: enclosingTasks) }

    /// Duplicate ranks are usable only while the source spanning the group,
    /// including continuation text and checkbox states, remains unchanged.
    static func twinRanks(
        of tasks: [MarkdownTask], in string: NSString
    ) -> [(index: Int, count: Int, fingerprint: String?)] {
        let groups = Dictionary(grouping: tasks, by: \.twins)
        let fingerprints = groups.compactMapValues { group -> String? in
            guard group.count > 1, let first = group.first, let last = group.last else { return nil }
            let start = string.lineRange(for: first.boxRange).location
            let end = last.ordinal + 1 < tasks.count
                ? string.lineRange(for: tasks[last.ordinal + 1].boxRange).location : string.length
            let source = string.substring(with: NSRange(location: start, length: end - start))
            return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        var counts: [Twins: Int] = [:]
        let indexes = tasks.map { task -> Int in
            defer { counts[task.twins, default: 0] += 1 }
            return counts[task.twins, default: 0]
        }
        return zip(tasks, indexes).map { ($1, counts[$0.twins]!, fingerprints[$0.twins]) }
    }

    /// For each box, the text of the boxes of the list items enclosing its
    /// item. List membership follows the shared lexer's block state, including
    /// list-contained fences which do not emit presentation list lines.
    private static func enclosingTasks(
        of boxes: [(range: NSRange, text: String)], listLines: [MarkdownListLine], startsOutsideList: Set<Int>
    ) -> [[String]] {
        var result = Array(repeating: [String](), count: boxes.count)
        var next = 0
        /// The open items of the current list, outermost first, with their box's text.
        var open: [(level: Int, task: String?)] = []
        for line in listLines {
            if startsOutsideList.contains(line.range.location) { open = [] }
            guard line.marker != nil else { continue }
            while let last = open.last, last.level >= line.level { open.removeLast() }
            while next < boxes.count, boxes[next].range.location < line.range.location { next += 1 }
            var task: String?
            if next < boxes.count, NSLocationInRange(boxes[next].range.location, line.range) {
                result[next] = open.compactMap(\.task)
                task = boxes[next].text
                next += 1
            }
            open.append((line.level, task))
        }
        return result
    }

    /// Quoted lists use the same block lexer after their quote prefix. Keep this
    /// semantic structure separate from the editor's unquoted layout metadata.
    private static func quotedListLines(
        tokens: [MarkdownToken], in string: NSString
    ) -> (lines: [MarkdownListLine], startsOutsideList: Set<Int>) {
        var lines: [MarkdownListLine] = []
        var startsOutsideList: Set<Int> = []
        var state = MarkdownLineState.documentStart
        var previousEnd: Int?
        var previousDepth = 0
        for token in tokens where token.kind == .blockquote {
            let units = Array(string.substring(with: token.range).utf16)
            var start = 0
            var depth = 0
            while start < units.count, units[start] == Char.gt {
                depth += 1
                start += 1
                if start < units.count, Char.isWhitespace(units[start]) { start += 1 }
                var next = start
                while next < units.count, Char.isWhitespace(units[next]) { next += 1 }
                if next < units.count, units[next] == Char.gt { start = next } else { break }
            }
            let range = string.lineRange(for: token.range)
            if previousEnd != range.location || previousDepth != depth { state = .documentStart }
            var lexer = MarkdownLineLexer(line: Array(units[start...]), offset: token.range.location + start)
            let next = lexer.lex(state: state, isFirstLine: false, nextLine: { nil })
            if var line = lexer.listLine {
                line.range = NSRange(location: range.location, length: token.range.upperBound - range.location)
                lines.append(line)
                if !state.isInList { startsOutsideList.insert(line.range.location) }
            }
            state = next
            previousEnd = range.upperBound
            previousDepth = depth
        }
        return (lines, startsOutsideList)
    }
}
