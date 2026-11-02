import Foundation

/// A literal source-line replacement, with UTF-16 ranges for the editor.
public struct SourceLineEdit: Sendable {
    public enum Command: CaseIterable, Sendable {
        case moveUp, moveDown, duplicateAbove, duplicateBelow
    }

    public let range: NSRange
    public let replacement: String
    public let selection: NSRange

    public static func canApply(_ command: Command, in source: String, selection: NSRange) -> Bool {
        guard let group = group(in: source as NSString, selection: selection) else { return false }
        switch command {
        case .moveUp: return group.start > 0
        case .moveDown: return group.end > group.contentsEnd
        case .duplicateAbove, .duplicateBelow: return true
        }
    }

    public static func edit(_ command: Command, in source: String, selection: NSRange) -> SourceLineEdit? {
        let text = source as NSString
        guard let group = group(in: text, selection: selection) else { return nil }
        let body = text.substring(with: NSRange(location: group.start, length: group.contentsEnd - group.start))
        let terminator = text.substring(with: NSRange(location: group.contentsEnd, length: group.end - group.contentsEnd))
        let range: NSRange
        let replacement: String
        let location: Int
        switch command {
        case .moveUp:
            guard group.start > 0 else { return nil }
            let previous = Line(in: text, at: group.start - 1)
            let prefix = text.substring(with: NSRange(location: previous.start, length: previous.contentsEnd - previous.start))
            let separator = text.substring(with: NSRange(location: previous.contentsEnd, length: previous.end - previous.contentsEnd))
            range = NSRange(location: previous.start, length: group.end - previous.start)
            replacement = body + separator + prefix + terminator
            location = selection.location - (group.start - previous.start)
        case .moveDown:
            guard group.end > group.contentsEnd else { return nil }
            let next = Line(in: text, at: group.end)
            let suffix = text.substring(with: NSRange(location: next.start, length: next.contentsEnd - next.start))
            let nextTerminator = text.substring(with: NSRange(location: next.contentsEnd, length: next.end - next.contentsEnd))
            range = NSRange(location: group.start, length: next.end - group.start)
            replacement = suffix + terminator + body + nextTerminator
            location = selection.location + (suffix as NSString).length + (terminator as NSString).length
        case .duplicateAbove, .duplicateBelow:
            let separator: String
            if !terminator.isEmpty {
                separator = terminator
            } else if group.start > 0 {
                let previous = Line(in: text, at: group.start - 1)
                separator = text.substring(with: NSRange(location: previous.contentsEnd, length: previous.end - previous.contentsEnd))
            } else {
                separator = "\n"
            }
            range = NSRange(location: group.start, length: group.end - group.start)
            replacement = body + separator + body + terminator
            location = selection.location + (command == .duplicateBelow ? (body as NSString).length + (separator as NSString).length : 0)
        }
        let end = text.length + (replacement as NSString).length - range.length
        return SourceLineEdit(
            range: range, replacement: replacement,
            selection: NSRange(location: location, length: min(selection.length, end - location))
        )
    }

    private struct Line {
        let start: Int
        let end: Int
        let contentsEnd: Int

        init(start: Int, end: Int, contentsEnd: Int) {
            self.start = start
            self.end = end
            self.contentsEnd = contentsEnd
        }

        init(in text: NSString, at location: Int) {
            var start = 0, end = 0, contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            self.start = start
            self.end = end
            self.contentsEnd = contentsEnd
        }
    }

    private static func group(in text: NSString, selection: NSRange) -> Line? {
        guard selection.location != NSNotFound, selection.location >= 0,
              selection.location <= text.length, selection.length >= 0,
              selection.length <= text.length - selection.location else { return nil }
        let first = Line(in: text, at: selection.location)
        let last = Line(in: text, at: selection.length > 0 ? selection.upperBound - 1 : selection.location)
        return Line(start: first.start, end: last.end, contentsEnd: last.contentsEnd)
    }
}
