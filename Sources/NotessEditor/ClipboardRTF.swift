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
        var segments: [RichTextLinkMarkdown.Segment] = []
        let text = attributed.string as NSString
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            let label = text.substring(with: range)
            if let destination = (value as? URL)?.absoluteString ?? value as? String {
                segments.append(.link(label: label, destination: destination))
            } else {
                segments.append(.text(label))
            }
        }
        return segments
    }
}
