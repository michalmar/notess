import Foundation
import NotessCore

/// Reads the visible text and hyperlinks of an HTML clipboard fragment.
///
/// A small tolerant scanner rather than `NSAttributedString`'s HTML import:
/// that one runs WebKit, spins the run loop and may fetch remote resources,
/// none of which a paste may do. Only text, line structure and `<a href>` are
/// kept; all other markup and styling is ignored.
enum ClipboardHTML {
    typealias Segment = RichTextLinkMarkdown.Segment

    // MARK: Bytes to text

    /// The HTML text of pasteboard data: UTF-16 or UTF-8 with or without a
    /// byte-order mark, else the charset the markup declares, else Windows Latin-1.
    static func string(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let bytes = [UInt8](data.prefix(4))
        var text: String?
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16)
        } else if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            text = String(data: data.dropFirst(3), encoding: .utf8)
        } else if bytes.count >= 2, bytes[0] != 0, bytes[1] == 0 {
            text = String(data: data, encoding: .utf16LittleEndian)
        } else if bytes.count >= 2, bytes[0] == 0, bytes[1] != 0 {
            text = String(data: data, encoding: .utf16BigEndian)
        } else if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else {
            text = String(data: data, encoding: declaredEncoding(in: data) ?? .windowsCP1252)
                ?? String(data: data, encoding: .isoLatin1)
        }
        return text?.trimmingPrefix("\u{FEFF}").description
    }

    private static func declaredEncoding(in data: Data) -> String.Encoding? {
        let head = String(decoding: data.prefix(2048), as: UTF8.self)
        guard let name = head.firstMatch(of: /(?i)charset\s*=\s*["']?([A-Za-z0-9_\-]+)/)?.output.1 else { return nil }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(String(name) as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    // MARK: Text and links

    static func segments(in html: String) -> [Segment] {
        var reader = Reader(Array(html.unicodeScalars))
        reader.read()
        return reader.builder.finish()
    }

    /// Block elements and the blank-line margin they put around themselves:
    /// a paragraph break (2) or a plain line break (1).
    private static let blockMargins: [String: Int] = {
        var margins: [String: Int] = [:]
        for name in ["p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "ul", "ol", "dl",
                     "table", "pre", "hr", "figure", "fieldset", "address"] {
            margins[name] = 2
        }
        for name in ["div", "li", "tr", "dt", "dd", "section", "article", "header", "footer", "nav",
                     "aside", "main", "form", "thead", "tbody", "tfoot", "caption", "center",
                     "details", "summary", "figcaption", "title"] {
            margins[name] = 1
        }
        return margins
    }()

    /// Collects the output: collapsed whitespace, pending line breaks and an
    /// optional open link whose text is its label.
    private struct Builder {
        private var segments: [Segment] = []
        private var text = ""
        private var label: String?
        private var destination = ""
        private var pendingSpace = false
        private var pendingBreaks = 0
        private var hasOutput = false
        private var atLineStart = true

        mutating func append(_ string: String, preformatted: Bool) {
            for scalar in string.unicodeScalars {
                if preformatted {
                    if scalar == "\r" { continue }
                    flushPending()
                    write(scalar == "\u{A0}" ? " " : String(scalar))
                } else if Self.isCollapsible(scalar) {
                    pendingSpace = true
                } else {
                    flushPending()
                    write(String(scalar))
                }
            }
        }

        mutating func lineBreak() { pendingBreaks += 1 }
        mutating func block(margin: Int) { pendingBreaks = max(pendingBreaks, margin) }
        mutating func space() { pendingSpace = true }

        mutating func openLink(to href: String) {
            closeLink()
            flushPending()
            if !text.isEmpty { segments.append(.text(text)) }
            text = ""
            label = ""
            destination = href
        }

        mutating func closeLink() {
            guard let label else { return }
            segments.append(.link(label: label, destination: destination))
            self.label = nil
        }

        mutating func finish() -> [Segment] {
            closeLink()
            if !text.isEmpty { segments.append(.text(text)) }
            text = ""
            if case .text(let last)? = segments.last {
                let trimmed = String(last.reversed().drop(while: { $0.isWhitespace }).reversed())
                segments.removeLast()
                if !trimmed.isEmpty { segments.append(.text(trimmed)) }
            }
            return segments
        }

        private mutating func flushPending() {
            if hasOutput {
                if pendingBreaks > 0 {
                    write(String(repeating: "\n", count: pendingBreaks))
                } else if pendingSpace && !atLineStart {
                    write(" ")
                }
            }
            pendingBreaks = 0
            pendingSpace = false
        }

        private mutating func write(_ string: String) {
            if label != nil { label?.append(string) } else { text.append(string) }
            hasOutput = true
            atLineStart = string.last == "\n"
        }

        private static func isCollapsible(_ scalar: Unicode.Scalar) -> Bool {
            scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar == "\u{0C}" || scalar == "\u{A0}"
        }
    }

    private struct Reader {
        let scalars: [Unicode.Scalar]
        var builder = Builder()
        private var index = 0
        private var inHead = false
        private var inTitle = false
        private var preformattedDepth = 0

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        mutating func read() {
            while index < scalars.count {
                if scalars[index] != "<" {
                    readText()
                } else if matches("<!--") {
                    skip(past: "-->", from: index + 4)
                } else if matches("<!") || matches("<?") {
                    skip(past: ">", from: index + 2)
                } else if matches("</"), let next = scalars[safe: index + 2], next.properties.isAlphabetic {
                    readEndTag()
                } else if let next = scalars[safe: index + 1], next.properties.isAlphabetic {
                    readStartTag()
                } else {
                    emit("<")
                    index += 1
                }
            }
        }

        private var isHidden: Bool { inHead || inTitle }

        private mutating func emit(_ text: String) {
            guard !isHidden else { return }
            builder.append(text, preformatted: preformattedDepth > 0)
        }

        private func matches(_ prefix: String) -> Bool {
            let expected = Array(prefix.unicodeScalars)
            guard index + expected.count <= scalars.count else { return false }
            return Array(scalars[index..<(index + expected.count)]) == expected
        }

        private mutating func skip(past terminator: String, from start: Int) {
            let end = Array(terminator.unicodeScalars)
            var i = start
            while i + end.count <= scalars.count {
                if Array(scalars[i..<(i + end.count)]) == end { index = i + end.count; return }
                i += 1
            }
            index = scalars.count
        }

        private mutating func readText() {
            let start = index
            while index < scalars.count && scalars[index] != "<" { index += 1 }
            emit(HTMLEntities.decode(String(String.UnicodeScalarView(scalars[start..<index]))))
        }

        private mutating func readName() -> String {
            let start = index
            while index < scalars.count, !scalars[index].properties.isWhitespace, scalars[index] != ">", scalars[index] != "/" {
                index += 1
            }
            return String(String.UnicodeScalarView(scalars[start..<index])).lowercased()
        }

        private mutating func readEndTag() {
            index += 2
            let name = readName()
            skip(past: ">", from: index)
            switch name {
            case "a": builder.closeLink()
            case "head": inHead = false
            case "title": inTitle = false; builder.block(margin: 1)
            case "pre": preformattedDepth = max(0, preformattedDepth - 1); builder.block(margin: 2)
            default:
                if !isHidden, let margin = ClipboardHTML.blockMargins[name] { builder.block(margin: margin) }
            }
        }

        private mutating func readStartTag() {
            index += 1
            let name = readName()
            let attributes = readAttributes()
            switch name {
            case "script", "style":
                skipRawText(until: "</\(name)")
            case "head": inHead = true
            case "body": inHead = false
            case "title": inTitle = true
            case "a":
                builder.closeLink()
                if !isHidden, let href = attributes["href"] { builder.openLink(to: href) }
            case "br": if !isHidden { builder.lineBreak() }
            case "td", "th": if !isHidden { builder.space() }
            case "pre":
                if !isHidden { builder.block(margin: 2) }
                preformattedDepth += 1
            default:
                if !isHidden, let margin = ClipboardHTML.blockMargins[name] { builder.block(margin: margin) }
            }
        }

        private mutating func readAttributes() -> [String: String] {
            var attributes: [String: String] = [:]
            while index < scalars.count {
                while index < scalars.count, scalars[index].properties.isWhitespace || scalars[index] == "/" { index += 1 }
                guard index < scalars.count else { break }
                if scalars[index] == ">" { index += 1; break }
                let nameStart = index
                while index < scalars.count, !scalars[index].properties.isWhitespace,
                      scalars[index] != "=", scalars[index] != ">", scalars[index] != "/" {
                    index += 1
                }
                let name = String(String.UnicodeScalarView(scalars[nameStart..<index])).lowercased()
                while index < scalars.count, scalars[index].properties.isWhitespace { index += 1 }
                var value = ""
                if index < scalars.count, scalars[index] == "=" {
                    index += 1
                    while index < scalars.count, scalars[index].properties.isWhitespace { index += 1 }
                    value = readAttributeValue()
                }
                if !name.isEmpty, attributes[name] == nil { attributes[name] = HTMLEntities.decode(value) }
                if index == nameStart { index += 1 }
            }
            return attributes
        }

        private mutating func readAttributeValue() -> String {
            guard index < scalars.count else { return "" }
            let start: Int
            if scalars[index] == "\"" || scalars[index] == "'" {
                let quote = scalars[index]
                index += 1
                start = index
                while index < scalars.count, scalars[index] != quote { index += 1 }
                let value = String(String.UnicodeScalarView(scalars[start..<index]))
                if index < scalars.count { index += 1 }
                return value
            }
            start = index
            while index < scalars.count, !scalars[index].properties.isWhitespace, scalars[index] != ">" { index += 1 }
            return String(String.UnicodeScalarView(scalars[start..<index]))
        }

        /// Leaves `index` at the closing tag of a `script` or `style`, whose
        /// content is not markup.
        private mutating func skipRawText(until closing: String) {
            let needle = Array(closing.unicodeScalars)
            var i = index
            while i + needle.count <= scalars.count {
                let candidate = scalars[i..<(i + needle.count)].map { Unicode.Scalar(String($0).lowercased()) ?? $0 }
                if candidate == needle { index = i; return }
                i += 1
            }
            index = scalars.count
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Decoding of HTML character references in text and attribute values.
enum HTMLEntities {
    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var remainder = Substring(text)
        while let ampersand = remainder.firstIndex(of: "&") {
            result += remainder[..<ampersand]
            let tail = remainder[ampersand...]
            if let match = tail.prefix(32).firstMatch(of: /^&(#[xX][0-9a-fA-F]+|#[0-9]+|[A-Za-z][A-Za-z0-9]*);/),
               let decoded = decodeReference(String(match.output.1)) {
                result += decoded
                remainder = tail.dropFirst(match.output.0.count)
            } else {
                result += "&"
                remainder = tail.dropFirst()
            }
        }
        return result + remainder
    }

    private static func decodeReference(_ reference: String) -> String? {
        if reference.hasPrefix("#") {
            let digits = reference.dropFirst()
            let value = digits.first == "x" || digits.first == "X"
                ? UInt32(digits.dropFirst(), radix: 16)
                : UInt32(digits, radix: 10)
            guard let value, value != 0, let scalar = Unicode.Scalar(value) else { return nil }
            return String(scalar)
        }
        return named[reference]
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
        "ensp": " ", "emsp": " ", "thinsp": " ", "copy": "©", "reg": "®", "trade": "™",
        "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’", "sbquo": "‚",
        "ldquo": "“", "rdquo": "”", "bdquo": "„", "laquo": "«", "raquo": "»", "bull": "•",
        "middot": "·", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "deg": "°",
        "plusmn": "±", "times": "×", "divide": "÷", "para": "¶", "sect": "§", "larr": "←",
        "rarr": "→", "uarr": "↑", "darr": "↓", "check": "✓", "zwnj": "\u{200C}", "zwj": "\u{200D}",
        "shy": "\u{AD}",
    ]
}
