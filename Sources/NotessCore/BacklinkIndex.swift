import Foundation

/// One source Section that contains a Wiki-link resolving to another note.
public struct Backlink: Hashable, Identifiable, Sendable {
    public let sourceRelativePath: String
    public let sectionTitle: String?
    public let preview: String
    public let sectionHeadingRange: NSRange?

    public var id: String {
        "\(sourceRelativePath)#\(sectionHeadingRange?.location ?? -1)"
    }

    public var sourceDisplayName: String {
        URL(fileURLWithPath: sourceRelativePath)
            .deletingPathExtension()
            .lastPathComponent
    }
}

/// A disposable, regenerable index of Wiki-links between notes in a Vault.
///
/// The actor owns file reading, parsing and resolution so callers can rebuild
/// or update the index without doing that work on the main actor.
public actor BacklinkIndex {
    private var noteTexts: [String: String] = [:]
    private var backlinksByTarget: [String: [Backlink]] = [:]

    public init() {}

    /// Rebuilds the complete index from the Markdown files in `vault`.
    public func rebuild(in vault: Vault) {
        let paths = vault.scanNotePaths()
        noteTexts = Dictionary(uniqueKeysWithValues: paths.compactMap { path in
            guard let text = Self.read(path, in: vault) else { return nil }
            return (path, text)
        })
        regenerate()
    }

    /// Replaces one saved note, while also accounting for files created,
    /// deleted or renamed since the previous generation.
    public func update(relativePath: String, content: String?, in vault: Vault) {
        let currentPaths = Set(vault.scanNotePaths())
        noteTexts = noteTexts.filter { currentPaths.contains($0.key) }
        for path in currentPaths where noteTexts[path] == nil {
            noteTexts[path] = Self.read(path, in: vault)
        }
        if currentPaths.contains(relativePath) {
            noteTexts[relativePath] = content ?? Self.read(relativePath, in: vault)
        } else {
            noteTexts.removeValue(forKey: relativePath)
        }
        regenerate()
    }

    /// All source Sections whose Wiki-links resolve to `relativePath`.
    public func backlinks(to relativePath: String) -> [Backlink] {
        backlinksByTarget[relativePath] ?? []
    }

    private func regenerate() {
        let resolver = WikiLinkResolver(relativePaths: Array(noteTexts.keys))
        var result: [String: [Backlink]] = [:]

        for (sourcePath, text) in noteTexts {
            let sections = NoteSection.headings(in: text).filter { $0.level == 2 }
            var recordedSectionsByTarget: Set<String> = []

            for link in WikiLink.links(in: text) {
                let targetPath = link.target.isEmpty
                    ? sourcePath
                    : resolver.resolve(target: link.target)
                guard let targetPath else { continue }

                let section = sections.first(where: {
                    NSLocationInRange(link.range.location, $0.range)
                })
                let sectionKey = section?.range.location ?? -1
                guard recordedSectionsByTarget.insert("\(targetPath)#\(sectionKey)").inserted else { continue }

                result[targetPath, default: []].append(
                    Backlink(
                        sourceRelativePath: sourcePath,
                        sectionTitle: section?.title,
                        preview: Self.preview(for: link, section: section, in: text),
                        sectionHeadingRange: section?.headingRange
                    )
                )
            }
        }

        backlinksByTarget = result.mapValues {
            $0.sorted {
                if $0.sourceRelativePath != $1.sourceRelativePath {
                    return $0.sourceRelativePath.localizedStandardCompare($1.sourceRelativePath) == .orderedAscending
                }
                return ($0.sectionHeadingRange?.location ?? -1) < ($1.sectionHeadingRange?.location ?? -1)
            }
        }
    }

    private static func preview(for link: WikiLink, section: NoteSection?, in text: String) -> String {
        let string = text as NSString
        let range: NSRange
        if let section {
            let headingLine = string.lineRange(for: section.headingRange)
            let start = NSMaxRange(headingLine)
            range = NSRange(location: start, length: max(0, NSMaxRange(section.range) - start))
        } else {
            range = string.lineRange(for: link.range)
        }
        let words = string.substring(with: range)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        let full = words.joined(separator: " ")
        guard full.count > 180 else { return full }
        return String(full.prefix(177)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func read(_ relativePath: String, in vault: Vault) -> String? {
        let url = vault.rootURL.appending(path: relativePath, directoryHint: .notDirectory)
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
