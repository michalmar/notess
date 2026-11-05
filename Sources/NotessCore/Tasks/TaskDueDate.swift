import Foundation

/// The interpretation of manually written `📅 YYYY-MM-DD` markers in Task
/// text. Ranges refer to the supplied text in UTF-16, just like Markdown tokens.
/// The same interpretation is shared by saved Task queries and source rendering.
public struct TaskDueDate: Hashable, Sendable {
    public enum State: Hashable, Sendable {
        case missing
        case valid(Day)
        case invalid
    }

    public struct Marker: Hashable, Sendable {
        public let range: NSRange
        public let rawValue: String
        public let day: Day?
    }

    public let state: State
    public let markers: [Marker]

    public var day: Day? {
        guard case .valid(let day) = state else { return nil }
        return day
    }

    /// `offset` maps a Task-text substring back into its source document.
    /// Code examples are not interpreted as date metadata.
    public static func parse(in text: String, offset: Int = 0) -> TaskDueDate {
        let string = text as NSString
        let code = MarkdownSyntax.tokens(in: text).filter {
            $0.kind == .inlineCode || $0.kind == .codeBlock || $0.kind == .frontMatter
        }
        let pattern = /📅(?:[ \t]+([^\s📅]*))?/
        let markers = text.matches(of: pattern).compactMap { match -> Marker? in
            var range = NSRange(match.range, in: text)
            guard !code.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { return nil }
            var candidate = match.1.map(String.init) ?? ""
            while let last = candidate.last, ".,;!?)]}".contains(last) {
                candidate.removeLast()
                range.length -= 1
            }
            return Marker(
                range: NSRange(location: range.location + offset, length: range.length),
                rawValue: string.substring(with: range),
                day: parseDay(candidate)
            )
        }
        let state: State
        if markers.isEmpty {
            state = .missing
        } else if let day = markers.first?.day, markers.allSatisfy({ $0.day == day }) {
            state = .valid(day)
        } else {
            state = .invalid
        }
        return TaskDueDate(state: state, markers: markers)
    }

    private static func parseDay(_ text: String) -> Day? {
        guard let match = text.wholeMatch(of: /([0-9]{4})-([0-9]{2})-([0-9]{2})/),
              let year = Int(match.1), let month = Int(match.2), let day = Int(match.3),
              year > 0, (1...12).contains(month), day > 0 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let days = calendar.range(of: .day, in: .month, for: first),
              days.contains(day) else { return nil }
        return Day(year: year, month: month, day: day)
    }
}
