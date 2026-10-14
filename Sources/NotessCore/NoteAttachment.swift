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
}
