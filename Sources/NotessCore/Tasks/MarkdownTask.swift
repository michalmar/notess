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
        let lexed = MarkdownLexer().relexAll(text: string)
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
        let enclosing = enclosingTasks(of: boxes.map { ($0.range, $0.text) }, listLines: lexed.listLines, in: string)
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

    /// For each of `tasks`, its position among its twins and how many there are.
    static func twinRanks(of tasks: [MarkdownTask]) -> [(index: Int, count: Int)] {
        var counts: [Twins: Int] = [:]
        let indexes = tasks.map { task -> Int in
            defer { counts[task.twins, default: 0] += 1 }
            return counts[task.twins, default: 0]
        }
        return zip(tasks, indexes).map { ($1, counts[$0.twins]!) }
    }

    /// For each box, the text of the boxes of the list items enclosing its
    /// item. A list ends where a line that is neither blank nor a list line
    /// comes between two list lines (a paragraph or a heading).
    private static func enclosingTasks(
        of boxes: [(range: NSRange, text: String)], listLines: [MarkdownListLine], in string: NSString
    ) -> [[String]] {
        var result = Array(repeating: [String](), count: boxes.count)
        var next = 0
        /// The open items of the current list, outermost first, with their box's text.
        var open: [(level: Int, task: String?)] = []
        var previousEnd: Int?
        for line in listLines {
            if let previousEnd, previousEnd <= line.range.location,
               !string.substring(with: NSRange(location: previousEnd, length: line.range.location - previousEnd))
                   .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                open = []
            }
            previousEnd = line.range.upperBound
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
}
