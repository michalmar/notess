import AppKit
import NotessCore

/// AppKit's RTF reader is local (unlike its WebKit-backed HTML reader).
/// Only visible text and link attributes leave this boundary.
enum ClipboardRTF {
    static func segments(in data: Data) throws -> [RichTextLinkMarkdown.Segment] {
        let attributed = try NSAttributedString(
            data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
        // AppKit cuts a HYPERLINK target off at its first `\u` escape, which
        // would point the link somewhere else: keep only the visible text.
        let keepsLinks = !hasUnicodeEscapeInHyperlinkTarget(data)
        if !keepsLinks { NSLog("RTF clipboard link targets contain Unicode escapes; pasting their text only") }
        var segments: [RichTextLinkMarkdown.Segment] = []
        let text = attributed.string as NSString
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            let label = text.substring(with: range)
            if keepsLinks, let destination = (value as? URL)?.absoluteString ?? value as? String {
                segments.append(.link(label: label, destination: target(fromAppKitLink: destination)))
            } else {
                segments.append(.text(label))
            }
        }
        return segments
    }

    private static func hasUnicodeEscapeInHyperlinkTarget(_ data: Data) -> Bool {
        let rtf = String(decoding: data, as: UTF8.self)
        return rtf.contains(/HYPERLINK\s+"(?:[^"\\]|\\[^u])*\\u-?[0-9]/)
    }

    /// AppKit keeps a HYPERLINK field's quoted switches (`\t "_blank"`,
    /// `\o "tip"`, `\l "bookmark"`) in the link, percent-encoded after the
    /// target's closing quote. Only `\l` names part of the target: its fragment.
    private static func target(fromAppKitLink link: String) -> String {
        guard let switches = link.firstMatch(of: /%22(?:%20)+%5C[A-Za-z].*$/) else { return link }
        var target = String(link[..<switches.range.lowerBound])
        let instruction = String(switches.output).removingPercentEncoding ?? ""
        if !target.contains("#"),
           let bookmark = instruction.firstMatch(of: /\\l\s+"([^"]+)/)?.output.1,
           let fragment = String(bookmark).addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) {
            target += "#" + fragment
        }
        return target
    }
}
