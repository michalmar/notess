import Foundation

enum FileTrash {
    static func moveToTrash(_ fileURL: URL) throws {
        try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
    }
}
