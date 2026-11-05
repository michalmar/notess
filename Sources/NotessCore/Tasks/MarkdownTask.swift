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

    /// Every Task of `text`, in source-text order.
    public static func tasks(in text: String) -> [MarkdownTask] {
        let string = text as NSString
        var result: [MarkdownTask] = []
        for token in MarkdownSyntax.tokens(in: text) {
            guard case .task(let isChecked) = token.kind else { continue }
            var lineEnd = 0
            var contentsEnd = 0
            string.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: token.range)
            let start = NSMaxRange(token.range)
            let line = string.substring(with: NSRange(location: start, length: max(0, contentsEnd - start)))
            result.append(MarkdownTask(
                ordinal: result.count,
                boxRange: token.range,
                text: line.trimmingCharacters(in: .whitespaces),
                isCompleted: isChecked
            ))
        }
        return result
    }
}
