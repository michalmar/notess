import Foundation

enum FileTrash {
    static func moveToTrash(_ fileURL: URL) throws {
        _ = try moveToTrashReturningURL(fileURL)
    }

    static func moveToTrashReturningURL(_ fileURL: URL) throws -> URL {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: fileURL, resultingItemURL: &resultingURL)
        guard let resultingURL else { throw FileTrashError.missingResultURL }
        return resultingURL as URL
    }
}

private enum FileTrashError: LocalizedError {
    case missingResultURL

    var errorDescription: String? {
        "Systém nevrátil umístění souboru v Koši."
    }
}
