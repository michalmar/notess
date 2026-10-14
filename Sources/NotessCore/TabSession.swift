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
        return open(try NoteDocument.open(
            fileURL: canonicalURL,
            newFileContent: newFileContent
        ))
    }

    /// Adds an already loaded note, or selects the tab for the same file.
    @discardableResult
    public func open(_ document: NoteDocument) -> NoteDocument {
        if let existing = documents.first(where: {
            Self.refersToSameFile($0.fileURL, document.fileURL)
        }) {
            activeDocument = existing
            return existing
        }

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

    public static func refersToSameFile(_ firstURL: URL, _ secondURL: URL) -> Bool {
        let first = canonicalURL(firstURL)
        let second = canonicalURL(secondURL)
        if let firstIdentity = resourceIdentity(for: first),
           let secondIdentity = resourceIdentity(for: second) {
            return firstIdentity == secondIdentity
        }

        let usesCaseSensitiveNames =
            volumeSupportsCaseSensitiveNames(for: first) != false
            || volumeSupportsCaseSensitiveNames(for: second) != false
        let firstPath = comparablePath(first.path, caseSensitive: usesCaseSensitiveNames)
        let secondPath = comparablePath(second.path, caseSensitive: usesCaseSensitiveNames)
        return firstPath == secondPath
    }

    private static func resourceIdentity(for url: URL) -> FileResourceIdentity? {
        guard let values = try? url.resourceValues(forKeys: [
            .fileResourceIdentifierKey,
            .volumeIdentifierKey,
        ]),
        let fileIdentifier = values.fileResourceIdentifier as? NSObject else {
            return nil
        }
        return FileResourceIdentity(
            fileIdentifier: fileIdentifier,
            volumeIdentifier: values.volumeIdentifier as? NSObject
        )
    }

    private static func volumeSupportsCaseSensitiveNames(for url: URL) -> Bool? {
        var candidate = url
        while true {
            if let values = try? candidate.resourceValues(forKeys: [
                .volumeSupportsCaseSensitiveNamesKey,
            ]),
            let supportsCaseSensitiveNames = values.volumeSupportsCaseSensitiveNames {
                return supportsCaseSensitiveNames
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
    }

    private static func comparablePath(_ path: String, caseSensitive: Bool) -> String {
        let normalized = path.precomposedStringWithCanonicalMapping
        guard !caseSensitive else { return normalized }
        return normalized.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

private struct FileResourceIdentity: Equatable {
    let fileIdentifier: NSObject
    let volumeIdentifier: NSObject?

    static func == (lhs: FileResourceIdentity, rhs: FileResourceIdentity) -> Bool {
        guard lhs.fileIdentifier.isEqual(rhs.fileIdentifier) else { return false }
        switch (lhs.volumeIdentifier, rhs.volumeIdentifier) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs.isEqual(rhs)
        default:
            return false
        }
    }
}
