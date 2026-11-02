import Foundation

/// Turns text that carries hyperlinks (from any rich-text clipboard
/// representation) into plain Markdown, keeping only the links.
///
/// A source supplies `Segment`s; everything it knows about styling is gone by
/// then. Destinations are kept exactly as given: no normalisation, redirect
/// resolution or guessing. Only valid absolute `http`, `https` and `mailto`
/// destinations stay links; any other link keeps just its visible text.
public enum RichTextLinkMarkdown {
    /// A run of visible text, or a named link with its underlying target.
    public enum Segment: Equatable, Sendable {
        case text(String)
        case link(label: String, destination: String)
    }

    /// The Markdown for `segments`, or `nil` when no `[label](destination)`
    /// would be written (no links, only links that cannot be kept, or only web
    /// links shown as their own URL) and the text should be pasted as ordinary text.
    public static func markdown(from segments: [Segment]) -> String? {
        var result = ""
        var wroteLink = false
        for segment in segments {
            switch segment {
            case .text(let text):
                result += text
            case .link(let rawLabel, let rawDestination):
                let label = Label(rawLabel)
                guard !label.core.isEmpty,
                      let destination = Destination(rawDestination),
                      !(destination.isWeb && label.core == destination.source) else {
                    result += label.text
                    continue
                }
                result += label.leading
                keepLinkOpening(after: &result)
                result += "[\(escapeLabel(label.core))](\(destination.encoded))"
                result += label.trailing
                wroteLink = true
            }
        }
        return wroteLink ? result : nil
    }

    /// The text a reader sees: the segments with their link destinations dropped.
    public static func visibleText(from segments: [Segment]) -> String {
        segments.map { segment in
            switch segment {
            case .text(let text): text
            case .link(let label, _): Label(label).text
            }
        }.joined()
    }

    /// A link label with its inner whitespace (including line breaks) collapsed
    /// to single spaces. Edge whitespace, such as a paragraph break, stays as
    /// it is but belongs outside the link.
    private struct Label {
        let leading: String
        let core: String
        let trailing: String
        var text: String { leading + core + trailing }

        init(_ raw: String) {
            let words = raw.split(whereSeparator: { $0.isWhitespace })
            core = words.joined(separator: " ")
            leading = String(raw.prefix(while: { $0.isWhitespace }))
            trailing = words.isEmpty ? "" : String(raw.reversed().prefix(while: { $0.isWhitespace }).reversed())
        }
    }

    /// A destination that may be kept as a link.
    private struct Destination {
        let source: String
        let isWeb: Bool

        init?(_ raw: String) {
            // As in browsers, ASCII tabs and line breaks inside a URL are dropped.
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .filter { $0 != "\t" && $0 != "\n" && $0 != "\r" && $0 != "\r\n" }
            guard !trimmed.isEmpty,
                  !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
                  let colon = trimmed.firstIndex(of: ":") else { return nil }
            let scheme = trimmed[..<colon].lowercased()
            let rest = trimmed[trimmed.index(after: colon)...]
            switch scheme {
            case "http", "https":
                guard rest.hasPrefix("//") else { return nil }
                let authority = rest.dropFirst(2).prefix(while: { !"/?#".contains($0) })
                let host = authority.split(separator: "@", omittingEmptySubsequences: false).last ?? ""
                guard !authority.contains(where: { $0.isWhitespace }),
                      !host.prefix(while: { $0 != ":" }).isEmpty else { return nil }
                isWeb = true
            case "mailto":
                let address = rest.prefix(while: { $0 != "?" })
                guard !address.isEmpty, !address.contains(where: { $0.isWhitespace }) else { return nil }
                isWeb = false
            default:
                return nil
            }
            source = trimmed
        }

        /// The destination as written inside `( )`: characters that would end
        /// or change the link are percent-encoded, which leaves the address
        /// itself unchanged.
        var encoded: String {
            let hasBalancedParens = Self.hasBalancedParentheses(source)
            var result = ""
            for scalar in source.unicodeScalars {
                let mustEncode: Bool
                switch scalar {
                case " ", "<", ">", "\\", "`": mustEncode = true
                case "(", ")": mustEncode = !hasBalancedParens
                default: mustEncode = scalar.properties.isWhitespace
                }
                if mustEncode {
                    for byte in String(scalar).utf8 { result += String(format: "%%%02X", byte) }
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
            return result
        }

        private static func hasBalancedParentheses(_ text: String) -> Bool {
            var depth = 0
            for character in text {
                if character == "(" { depth += 1 }
                if character == ")" { depth -= 1 }
                if depth < 0 { return false }
            }
            return depth == 0
        }
    }

    /// Keeps the `[` about to be written opening a link rather than being
    /// escaped by a trailing backslash or turned into an image by a trailing `!`.
    private static func keepLinkOpening(after text: inout String) {
        func trailingBackslashes(_ text: Substring) -> Int {
            text.reversed().prefix(while: { $0 == "\\" }).count
        }
        if trailingBackslashes(text[...]).isMultiple(of: 2) == false {
            text += "\\"
        } else if text.hasSuffix("!"), trailingBackslashes(text.dropLast()).isMultiple(of: 2) {
            text.insert("\\", at: text.index(before: text.endIndex))
        }
    }

    /// Backslash-escapes what would otherwise be read as Markdown inside link
    /// text. A lone `&` stays as is; one that starts a character reference does not.
    private static func escapeLabel(_ label: String) -> String {
        var result = ""
        var remainder = Substring(label)
        while let character = remainder.first {
            switch character {
            case "\\", "`", "*", "_", "[", "]", "<", ">", "~":
                result += "\\"
            case "&" where remainder.prefix(32).firstMatch(of: /^&(#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]*);/) != nil:
                result += "\\"
            default:
                break
            }
            result.append(character)
            remainder = remainder.dropFirst()
        }
        return result
    }
}
