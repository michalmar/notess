import Foundation
import Observation

public struct TabRestorationState: Codable, Equatable, Sendable {
    public let relativePaths: [String]
    public let activeRelativePath: String?

    public init(relativePaths: [String], activeRelativePath: String?) {
        self.relativePaths = relativePaths
        self.activeRelativePath = activeRelativePath
    }
}

/// The ordered set of open note tabs and the currently active note.
@MainActor
@Observable
public final class TabSession {
    public private(set) var documents: [NoteDocument] = []
    public private(set) var activeDocument: NoteDocument?

    public init() {}

    public var unsavedDocuments: [NoteDocument] {
        documents.filter(\.hasUnsavedChanges)
    }

    public var hasUnsavedChanges: Bool {
        documents.contains(where: \.hasUnsavedChanges)
    }

    /// Opens a note or selects its existing tab when the same file is already open.
    @discardableResult
    public func openNote(at fileURL: URL, newFileContent: String = "") throws -> NoteDocument {
        let canonicalURL = Self.canonicalURL(fileURL)
        if let existing = documents.first(where: {
            Self.canonicalURL($0.fileURL) == canonicalURL
        }) {
            activeDocument = existing
            return existing
        }

        let document = try NoteDocument.open(
            fileURL: canonicalURL,
            newFileContent: newFileContent
        )
        documents.append(document)
        activeDocument = document
        return document
    }

    public func select(documentID: NoteDocument.ID) {
        guard let document = documents.first(where: { $0.id == documentID }) else { return }
        activeDocument = document
    }

    public func closeTab(documentID: NoteDocument.ID) {
        guard let index = documents.firstIndex(where: { $0.id == documentID }) else { return }
        let wasActive = activeDocument?.id == documentID
        documents.remove(at: index)
        if wasActive {
            activeDocument = documents.isEmpty ? nil : documents[min(index, documents.count - 1)]
        }
    }

    public func restorationState(relativeTo rootURL: URL) -> TabRestorationState {
        let rootComponents = Self.canonicalURL(rootURL).pathComponents
        let pathsByID = documents.reduce(into: [NoteDocument.ID: String]()) { result, document in
            let components = Self.canonicalURL(document.fileURL).pathComponents
            guard components.starts(with: rootComponents) else { return }
            result[document.id] = components.dropFirst(rootComponents.count).joined(separator: "/")
        }
        return TabRestorationState(
            relativePaths: documents.compactMap { pathsByID[$0.id] },
            activeRelativePath: activeDocument.flatMap { pathsByID[$0.id] }
        )
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
