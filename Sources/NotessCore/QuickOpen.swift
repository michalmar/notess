import Foundation

/// A searchable Markdown file in a Vault.
public struct QuickOpenFile: Hashable, Sendable, Identifiable {
    public let relativePath: String
    public let kind: NoteKind

    public init(relativePath: String, kind: NoteKind) {
        self.relativePath = relativePath
        self.kind = kind
    }

    public var id: String { relativePath }
    public var name: String {
        URL(filePath: relativePath).deletingPathExtension().lastPathComponent
    }
    public var isReadOnly: Bool { kind == .brainNote }
}

/// Fuzzy ranking for the Vault's quick file picker.
public enum QuickOpen {
    /// Returns filename and path matches, ranking exact and prefix filename matches first.
    public static func rankedFiles(matching query: String, in files: [QuickOpenFile]) -> [QuickOpenFile] {
        let normalizedQuery = normalized(query)
        guard !normalizedQuery.isEmpty else {
            return files.sorted { localizedOrder($0.relativePath, $1.relativePath) }
        }

        var ranked: [(file: QuickOpenFile, score: Int)] = []
        for file in files {
            guard let fileScore = score(file, query: normalizedQuery) else { continue }
            ranked.append((file, fileScore))
        }
        return ranked
        .sorted {
            $0.1 == $1.1
                ? localizedOrder($0.0.relativePath, $1.0.relativePath)
                : $0.1 > $1.1
        }
        .map(\.0)
    }

    private static func score(_ file: QuickOpenFile, query: String) -> Int? {
        let name = normalized(file.name)
        let path = normalized(file.relativePath)
        if name == query { return 10_000 }
        if name.hasPrefix(query) { return 8_000 }
        if let range = name.range(of: query) {
            return 6_000 - name.distance(from: name.startIndex, to: range.lowerBound)
        }
        if path.hasPrefix(query) { return 4_000 }
        guard let fuzzyScore = fuzzyScore(query, in: path) else { return nil }
        return fuzzyScore
    }

    private static func fuzzyScore(_ query: String, in candidate: String) -> Int? {
        var nextIndex = candidate.startIndex
        var score = 1_000
        var previousMatch: String.Index?

        for character in query {
            guard let match = candidate[nextIndex...].firstIndex(of: character) else { return nil }
            let distance = candidate.distance(from: nextIndex, to: match)
            score -= distance * 4
            if let previousMatch,
               candidate.index(after: previousMatch) == match {
                score += 12
            }
            previousMatch = match
            nextIndex = candidate.index(after: match)
        }
        return score
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
    }

    private static func localizedOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}

extension Vault {
    /// Scans all visible Markdown files that can be opened from a Vault.
    public func quickOpenFiles() -> [QuickOpenFile] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let root = rootURL.resolvingSymlinksInPath().path + "/"
        var files: [QuickOpenFile] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
            else { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(root) else { continue }
            let relativePath = String(path.dropFirst(root.count))
            guard relativePath.hasSuffix(".md") else { continue }
            let kind = NoteKind.classify(relativePath: relativePath) ?? .freeNote
            files.append(QuickOpenFile(relativePath: relativePath, kind: kind))
        }
        return files.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }
}
