import AppKit
import ImageIO
import NotessCore
import UniformTypeIdentifiers

/// Why Copy as HTML left the clipboard unchanged.
public enum CopyAsHTMLError: LocalizedError, Equatable {
    /// A selected image stored with the note is missing or cannot be read.
    case unreadableLocalImage(source: String)
    /// A selected image stored with the note is not an image that can be
    /// exported.
    case unexportableLocalImage(source: String)

    public var errorDescription: String? {
        switch self {
        case .unreadableLocalImage(let source):
            "Obrázek „\(source)“ se nepodařilo najít nebo načíst. Schránka zůstala beze změny."
        case .unexportableLocalImage(let source):
            "Obrázek „\(source)“ nelze zkopírovat, protože to není podporovaný obrázek. Schránka zůstala beze změny."
        }
    }
}

extension MarkdownTextView {
    static let copyAsHTMLTitle = "Kopírovat jako HTML"

    /// Puts the selection on the clipboard as rendered HTML plus readable
    /// plain text. The export is prepared completely before the clipboard is
    /// replaced, so a failure leaves it as it was.
    @objc public func copyAsHTML(_ sender: Any?) {
        guard canCopyAsHTML else {
            NSSound.beep()
            return
        }
        let output: MarkdownExport.Output
        do {
            output = try MarkdownExport.render(string, selection: selectedRange(), embedLocalImage: embedLocalImageForHTML)
        } catch {
            NSSound.beep()
            onCopyAsHTMLFailure?(error)
            return
        }
        guard !output.isEmpty else {
            NSSound.beep()
            return
        }
        pasteboard.clearContents()
        pasteboard.setData(Data(output.html.utf8), forType: .html)
        pasteboard.setString(output.plainText, forType: .string)
    }

    /// The `src` that embeds a selected local image in the copied HTML: its
    /// bytes as a data URL, so recipients need neither the Vault nor the file.
    ///
    /// An image that cannot be read or exported fails the whole copy rather
    /// than being dropped or replaced with its description.
    func embedLocalImageForHTML(_ image: MarkdownExport.LocalImage) throws -> String {
        guard let data = localImageData(source: image.source, noteURL: noteURL) else {
            throw CopyAsHTMLError.unreadableLocalImage(source: image.source)
        }
        guard let portable = PortableImage(data) else {
            throw CopyAsHTMLError.unexportableLocalImage(source: image.source)
        }
        return "data:\(portable.mimeType);base64,\(portable.data.base64EncodedString())"
    }

    /// Enabled for one nonempty selection in selectable text.
    var canCopyAsHTML: Bool {
        isSelectable && selectedRanges.count == 1 && selectedRange().length > 0
    }

    /// Whether Copy as HTML is enabled, or `nil` for any other action.
    func validateCopyAsHTML(_ action: Selector?) -> Bool? {
        action == #selector(copyAsHTML(_:)) ? canCopyAsHTML : nil
    }

    /// Adds Copy as HTML right after Copy in the context menu.
    func addCopyAsHTMLItem(to menu: NSMenu) {
        guard isSelectable, !menu.items.contains(where: { $0.action == #selector(copyAsHTML(_:)) }) else { return }
        let item = NSMenuItem(title: Self.copyAsHTMLTitle, action: #selector(copyAsHTML(_:)), keyEquivalent: "")
        item.target = self
        if let copy = menu.items.firstIndex(where: { $0.action == #selector(copy(_:)) }) {
            menu.insertItem(item, at: copy + 1)
        } else {
            menu.addItem(item)
        }
    }
}

/// Image bytes in a format recipients such as Mail and browsers display.
/// PNG, JPEG and GIF keep their original bytes; other decodable images are
/// converted to PNG.
struct PortableImage {
    let data: Data
    let mimeType: String

    private static let portableTypes: [UTType] = [.png, .jpeg, .gif]

    init?(_ data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        if let portable = Self.portableTypes.first(where: { type.conforms(to: $0) }),
           let mimeType = portable.preferredMIMEType {
            self.data = data
            self.mimeType = mimeType
            return
        }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        self.data = png as Data
        self.mimeType = "image/png"
    }
}
