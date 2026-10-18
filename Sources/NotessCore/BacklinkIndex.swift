import Foundation

/// One source Section that contains a Wiki-link resolving to another note.
public struct Backlink: Hashable, Identifiable, Sendable {
    public let sourceRelativePath: String
    public let sectionTitle: String?
    public let sectionTitleOccurrence: Int?
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
///
/// Updates are incremental: each note's Wiki-links and Sections are parsed
/// from one token stream and kept until its text changes, so an update parses
/// only the notes whose text changed. When notes appear or disappear, only
/// the links whose target could now resolve differently are resolved again.
public actor BacklinkIndex {
    /// Work for `apply(_:in:)`; updates arriving while one is applied merge
    /// into one (see `CoalescingQueue`).
    public struct Update: Equatable, Sendable {
        /// Parse every note again (the full recovery path).
        public var rebuild = false
        /// Files or folders to read again, `""` for everything; see `update(changedPaths:savedContents:in:)`.
        public var changedPaths: Set<String> = []
        /// Just-saved note texts by path.
        public var savedContents: [String: String] = [:]

        public init(rebuild: Bool = false, changedPaths: Set<String> = [], savedContents: [String: String] = [:]) {
            self.rebuild = rebuild
            self.changedPaths = changedPaths
            self.savedContents = savedContents
        }

        /// Nothing to change; applying it only lets the caller reload what it shows.
        public var isEmpty: Bool {
            !rebuild && changedPaths.isEmpty && savedContents.isEmpty
        }

        /// Adds `later`; a later save of the same note wins.
        public mutating func merge(_ later: Update) {
            rebuild = rebuild || later.rebuild
            changedPaths.formUnion(later.changedPaths)
            savedContents.merge(later.savedContents) { _, newer in newer }
        }
    }

    /// One Wiki-link of a source note with everything its backlink needs.
    private struct ParsedLink: Sendable {
        let target: String
        let matchKey: String
        let sectionKey: Int
        let sectionTitle: String?
        let sectionTitleOccurrence: Int?
        let sectionHeadingRange: NSRange?
        let preview: String
    }

    private struct Source: Sendable {
        let text: String
        let links: [ParsedLink]
        var backlinksByTarget: [String: [Backlink]] = [:]
        var targets: Set<String> = []
    }

    private let tokenize: @Sendable (String) -> [MarkdownToken]
    private var sources: [String: Source] = [:]
    private var resolver = WikiLinkResolver(relativePaths: [])
    /// Source paths by the match keys of their links.
    private var sourcesByMatchKey: [String: Set<String>] = [:]
    private var backlinksByTarget: [String: [Backlink]] = [:]

    public init() {
        self.init(tokenize: { MarkdownSyntax.tokens(in: $0) })
    }

    /// - Parameter tokenize: Produces a note's Markdown tokens; replaceable to
    ///   count parsing in tests.
    init(tokenize: @escaping @Sendable (String) -> [MarkdownToken]) {
        self.tokenize = tokenize
    }

    /// Rebuilds the complete index from the Markdown files in `vault`,
    /// parsing every note again.
    public func rebuild(in vault: Vault) {
        sources = [:]
        sourcesByMatchKey = [:]
        backlinksByTarget = [:]
        var texts: [String: String] = [:]
        for path in vault.scanNotePaths() {
            texts[path] = Self.read(path, in: vault)
        }
        apply(texts: texts, removed: [])
    }

    /// Replaces one saved note, while also accounting for files created,
    /// deleted or renamed since the previous generation.
    public func update(relativePath: String, content: String?, in vault: Vault) {
        update(
            changedPaths: content == nil ? [relativePath] : [],
            savedContents: content.map { [relativePath: $0] } ?? [:],
            in: vault
        )
    }

    /// Catches up with the Vault: notes created, deleted or renamed since the
    /// previous generation, the files in `changedPaths` (a note, a folder, or
    /// `""` for everything) read again, and `savedContents` (by path) as just
    /// saved. A path that is also in `changedPaths` is read from disk instead.
    public func update(
        changedPaths: Set<String>,
        savedContents: [String: String] = [:],
        in vault: Vault
    ) {
        let currentPaths = Set(vault.scanNotePaths())
        let change = VaultChange(relativePaths: changedPaths)
        var removed = Set(sources.keys).subtracting(currentPaths)
        var texts: [String: String] = [:]
        for path in currentPaths {
            let text: String?
            let isChanged = change.affects(relativePath: path)
            if let saved = savedContents[path], !isChanged {
                text = saved
            } else if sources[path] == nil || isChanged {
                text = Self.read(path, in: vault)
            } else {
                continue
            }
            // An unreadable note counts as deleted until it can be read again.
            if let text { texts[path] = text } else { removed.insert(path) }
        }
        apply(texts: texts, removed: removed)
    }

    public func apply(_ update: Update, in vault: Vault) {
        if update.rebuild {
            rebuild(in: vault)
        } else if !update.isEmpty {
            self.update(changedPaths: update.changedPaths, savedContents: update.savedContents, in: vault)
        }
    }

    /// All source Sections whose Wiki-links resolve to `relativePath`.
    public func backlinks(to relativePath: String) -> [Backlink] {
        backlinksByTarget[relativePath] ?? []
    }

    /// Takes `texts` as the current text of those notes and drops `removed`,
    /// then resolves again what this can change.
    private func apply(texts: [String: String], removed: Set<String>) {
        let oldCandidates = Set(sources.keys)
        var toResolve: Set<String> = []
        var dropped: [String: Source] = [:]

        for path in removed {
            guard let source = sources.removeValue(forKey: path) else { continue }
            dropped[path] = source
        }
        for (path, text) in texts {
            if let existing = sources[path], existing.text == text { continue }
            if let existing = sources.removeValue(forKey: path) { dropped[path] = existing }
            sources[path] = Source(text: text, links: parse(text))
            toResolve.insert(path)
        }

        for (path, source) in dropped {
            for link in source.links {
                sourcesByMatchKey[link.matchKey]?.remove(path)
            }
            removeBacklinks(of: path, from: source.targets)
        }
        for path in toResolve {
            for link in sources[path]!.links {
                sourcesByMatchKey[link.matchKey, default: []].insert(path)
            }
        }

        let newCandidates = Set(sources.keys)
        let changedCandidates = oldCandidates.symmetricDifference(newCandidates)
        if !changedCandidates.isEmpty {
            resolver = WikiLinkResolver(relativePaths: Array(newCandidates))
            for path in changedCandidates {
                for key in WikiLinkResolver.matchKeys(forPath: path) {
                    toResolve.formUnion(sourcesByMatchKey[key] ?? [])
                }
            }
        }

        var touchedTargets: Set<String> = []
        for path in toResolve {
            guard var source = sources[path] else { continue }
            removeBacklinks(of: path, from: source.targets)
            touchedTargets.formUnion(source.targets)
            source.backlinksByTarget = resolve(source.links, from: path)
            source.targets = Set(source.backlinksByTarget.keys)
            sources[path] = source
        }
        for path in toResolve {
            guard let source = sources[path] else { continue }
            for (target, backlinks) in source.backlinksByTarget {
                backlinksByTarget[target, default: []].append(contentsOf: backlinks)
                touchedTargets.insert(target)
            }
        }
        for target in touchedTargets {
            guard let backlinks = backlinksByTarget[target], !backlinks.isEmpty else {
                backlinksByTarget.removeValue(forKey: target)
                continue
            }
            backlinksByTarget[target] = backlinks.sorted(by: Self.precedes)
        }
    }

    private func removeBacklinks(of sourcePath: String, from targets: Set<String>) {
        for target in targets {
            backlinksByTarget[target]?.removeAll { $0.sourceRelativePath == sourcePath }
            if backlinksByTarget[target]?.isEmpty == true {
                backlinksByTarget.removeValue(forKey: target)
            }
        }
    }

    /// Parses a note once: its Sections and Wiki-links share one token stream.
    private func parse(_ text: String) -> [ParsedLink] {
        let tokens = tokenize(text)
        let sections = NoteSection.headings(in: text, tokens: tokens).filter { $0.level == 2 }
        var previews: [Int: String] = [:]
        return WikiLink.links(in: text, tokens: tokens).compactMap { link in
            guard !link.target.isEmpty,
                  let matchKey = WikiLinkResolver.matchKey(forTarget: link.target) else { return nil }
            let sectionIndex = sections.firstIndex(where: {
                NSLocationInRange(link.range.location, $0.range)
            })
            let section = sectionIndex.map { sections[$0] }
            let sectionOccurrence = sectionIndex.map { index in
                sections[..<index].count {
                    NoteSection.normalize($0.title) == NoteSection.normalize(sections[index].title)
                }
            }
            let preview: String
            if let section {
                let key = section.range.location
                preview = previews[key] ?? Self.preview(for: link, section: section, in: text)
                previews[key] = preview
            } else {
                preview = Self.preview(for: link, section: nil, in: text)
            }
            return ParsedLink(
                target: link.target,
                matchKey: matchKey,
                sectionKey: section?.range.location ?? -1,
                sectionTitle: section?.title,
                sectionTitleOccurrence: sectionOccurrence,
                sectionHeadingRange: section?.headingRange,
                preview: preview
            )
        }
    }

    /// One backlink per target and source Section, from the first link to it.
    private func resolve(_ links: [ParsedLink], from sourcePath: String) -> [String: [Backlink]] {
        var result: [String: [Backlink]] = [:]
        var recordedSectionsByTarget: Set<String> = []
        var resolved: [String: String?] = [:]
        for link in links {
            let targetPath: String?
            if let cached = resolved[link.target] {
                targetPath = cached
            } else {
                targetPath = resolver.resolve(target: link.target)
                resolved[link.target] = .some(targetPath)
            }
            guard let targetPath,
                  recordedSectionsByTarget.insert("\(targetPath)#\(link.sectionKey)").inserted
            else { continue }
            result[targetPath, default: []].append(
                Backlink(
                    sourceRelativePath: sourcePath,
                    sectionTitle: link.sectionTitle,
                    sectionTitleOccurrence: link.sectionTitleOccurrence,
                    preview: link.preview,
                    sectionHeadingRange: link.sectionHeadingRange
                )
            )
        }
        return result
    }

    private static func precedes(_ a: Backlink, _ b: Backlink) -> Bool {
        if a.sourceRelativePath != b.sourceRelativePath {
            switch a.sourceRelativePath.localizedStandardCompare(b.sourceRelativePath) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.sourceRelativePath < b.sourceRelativePath
            }
        }
        return (a.sectionHeadingRange?.location ?? -1) < (b.sectionHeadingRange?.location ?? -1)
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
