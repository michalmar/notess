import AppKit
import NotessCore

/// The text a pasteboard with rich (HTML or RTF) representations yields for a
/// note. One complete representation is used, never text or targets combined
/// from different formats.
struct RichClipboard {
    let pasteboard: NSPasteboard

    private struct Format: Sendable {
        let type: NSPasteboard.PasteboardType
        let name: String
        let segments: @Sendable (Data) throws -> [RichTextLinkMarkdown.Segment]
    }

    /// Precedence order: usable HTML links win over RTF links.
    private static let formats = [
        Format(type: .html, name: "HTML", segments: ClipboardHTML.segments(in:)),
        Format(type: .rtf, name: "RTF", segments: ClipboardRTF.segments(in:)),
    ]

    var offersRichText: Bool {
        pasteboard.types?.contains { type in Self.formats.contains { $0.type == type } } == true
    }

    /// Markdown links from the first format with a usable link; otherwise the
    /// visible text. `nil` when no representation yields any text.
    func linkPreservingText() -> String? {
        text(preservingLinks: true)
    }

    /// Plain text first, then the visible text of readable HTML, then RTF.
    func visibleText() -> String? {
        text(preservingLinks: false)
    }

    private func text(preservingLinks: Bool) -> String? {
        let plain = pasteboard.string(forType: .string).flatMap { $0.isEmpty ? nil : $0 }
        if !preservingLinks, let plain { return plain }
        var visible: String?
        for format in Self.formats {
            guard let segments = segments(of: format) else { continue }
            if preservingLinks, let markdown = RichTextLinkMarkdown.markdown(from: segments) {
                return markdown
            }
            let text = RichTextLinkMarkdown.visibleText(from: segments)
            if visible == nil, !text.isEmpty { visible = text }
        }
        return plain ?? visible
    }

    private func segments(of format: Format) -> [RichTextLinkMarkdown.Segment]? {
        guard pasteboard.types?.contains(format.type) == true else { return nil }
        guard let data = pasteboard.data(forType: format.type) else {
            NSLog("Could not read %@ clipboard data", format.name)
            return nil
        }
        if data.isEmpty { return nil }
        do {
            return try format.segments(data)
        } catch {
            NSLog("Could not decode %@ clipboard text: %@", format.name, error.localizedDescription)
            return nil
        }
    }
}
