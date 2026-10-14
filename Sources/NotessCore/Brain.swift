import Foundation

/// One kind of Entity the second brain tracks, with the `_brain/` sub-folder its Brain Notes live in.
public struct EntityType: Equatable, Sendable, Identifiable {
    /// Folder name relative to `_brain/`, without slashes (e.g. `people`).
    public let folder: String
    public var id: String { folder }

    public init(folder: String) {
        self.folder = folder
    }

    /// Heading shown in the sidebar.
    public var title: String {
        folder.prefix(1).uppercased() + folder.dropFirst()
    }

    public static let defaults = ["people", "companies", "projects", "places"].map(EntityType.init(folder:))
}

/// Brain Notes grouped by Entity type, as shown in the sidebar.
public struct BrainTree: Equatable, Sendable {
    public struct Note: Equatable, Sendable, Identifiable {
        public let relativePath: String
        public let title: String
        public var id: String { relativePath }
    }

    public struct Group: Equatable, Sendable, Identifiable {
        public let title: String
        /// Vault-relative folder, e.g. `_brain/people`.
        public let relativePath: String
        public let notes: [Note]
        public var id: String { relativePath }
    }

    /// One group per Entity type of `_brain/AGENTS.md` (even when empty), then
    /// a group for Brain Notes that sit outside those folders.
    public let groups: [Group]

    public static let empty = BrainTree(groups: [])
}

extension Vault {
    public static let brainInstructionsRelativePath = "\(NoteKind.brainFolder)/AGENTS.md"

    public var brainInstructionsURL: URL {
        rootURL.appending(path: Self.brainInstructionsRelativePath, directoryHint: .notDirectory)
    }

    /// Creates the default `_brain/AGENTS.md` if the file is missing. An existing file,
    /// whatever its content, is never touched. Returns whether the file was created.
    @discardableResult
    public func ensureBrainInstructions() throws -> Bool {
        let url = brainInstructionsURL
        guard !isBrainFolderSymlink else { throw CocoaError(.fileWriteNoPermission) }
        guard !FileManager.default.fileExists(atPath: url.path) else { return false }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try Data(BrainInstructions.defaultContent.utf8).write(to: url, options: .withoutOverwriting)
            return true
        } catch CocoaError.fileWriteFileExists {
            return false
        }
    }

    /// The Entity types listed in `_brain/AGENTS.md`; the defaults if the file is
    /// missing, unreadable or lists none.
    public func entityTypes() -> [EntityType] {
        guard !isBrainFolderSymlink,
              let text = try? String(contentsOf: brainInstructionsURL, encoding: .utf8) else {
            return EntityType.defaults
        }
        let types = BrainInstructions.entityTypes(in: text)
        return types.isEmpty ? EntityType.defaults : types
    }

    /// A symlinked `_brain` could lead outside the Vault, so nothing is read or written through it.
    private var isBrainFolderSymlink: Bool {
        let url = rootURL.appending(path: NoteKind.brainFolder, directoryHint: .isDirectory)
        return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    func scanBrain() -> BrainTree {
        let types = entityTypes()
        var groups = types.map { scanBrainGroup(folder: $0.folder, title: $0.title) }
        let known = Set(types.map(\.folder))
        // Notes directly in `_brain/` and in folders that are not Entity types.
        let strays = brainFolderNames().filter { !known.contains($0) }
            .flatMap { scanBrainGroup(folder: $0, title: $0).notes }
        let loose = scanBrainGroup(folder: nil, title: "").notes + strays
        if !loose.isEmpty {
            groups.append(.init(title: "Ostatní", relativePath: NoteKind.brainFolder, notes: loose))
        }
        return BrainTree(groups: groups)
    }

    private func brainFolderNames() -> [String] {
        guard !isBrainFolderSymlink else { return [] }
        let url = rootURL.appending(path: NoteKind.brainFolder, directoryHint: .isDirectory)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter {
                let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values?.isDirectory == true && values?.isSymbolicLink != true
            }
            .map(\.lastPathComponent)
            .filter { $0 != NoteKind.attachmentsFolder }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Brain Notes directly in `_brain/<folder>` (or `_brain/` itself for `nil`).
    private func scanBrainGroup(folder: String?, title: String) -> BrainTree.Group {
        let relativeFolder = folder.map { "\(NoteKind.brainFolder)/\($0)" } ?? NoteKind.brainFolder
        let url = rootURL.appending(path: relativeFolder, directoryHint: .isDirectory)
        if isBrainFolderSymlink
            || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return .init(title: title, relativePath: relativeFolder, notes: [])
        }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var notes: [BrainTree.Note] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            let path = "\(relativeFolder)/\(entry.lastPathComponent)"
            guard NoteKind.classify(relativePath: path) == .brainNote else { continue }
            notes.append(.init(relativePath: path, title: String(entry.lastPathComponent.dropLast(3))))
        }
        notes.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return .init(title: title, relativePath: relativeFolder, notes: notes)
    }
}
