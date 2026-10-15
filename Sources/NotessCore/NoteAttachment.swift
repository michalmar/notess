import Foundation

/// Image bytes staged for a note and written with the note on explicit save.
public struct NoteAttachment: Sendable {
    public let data: Data
    public let relativePath: String
    public let fileURL: URL

    public var markdown: String {
        "![](\(relativePath))"
    }

    public static func plan(
        data: Data,
        fileExtension: String,
        for noteURL: URL,
        id: UUID = UUID()
    ) -> NoteAttachment {
        let normalizedExtension = fileExtension
            .lowercased()
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let suffix = normalizedExtension.isEmpty ? "png" : normalizedExtension
        let filename = "image-\(id.uuidString.lowercased()).\(suffix)"
        let relativePath = "attachments/\(filename)"
        let fileURL = noteURL.deletingLastPathComponent()
            .appending(path: relativePath, directoryHint: .notDirectory)
        return NoteAttachment(data: data, relativePath: relativePath, fileURL: fileURL)
    }

    /// The text that replaces `range` of `text` so that `markdown` ends up on a
    /// line of its own: a line break is added before and after it only where the
    /// surrounding text does not already end or start a line.
    public static func standaloneLine(
        _ markdown: String,
        replacing range: NSRange,
        in text: String
    ) -> String {
        let string = text as NSString
        func isLineBreak(at index: Int) -> Bool {
            let character = string.character(at: index)
            return character == 0x0A || character == 0x0D
        }
        let needsLeadingBreak = range.location > 0 && !isLineBreak(at: range.location - 1)
        let needsTrailingBreak = range.upperBound < string.length && !isLineBreak(at: range.upperBound)
        return (needsLeadingBreak ? "\n" : "") + markdown + (needsTrailingBreak ? "\n" : "")
    }
}
