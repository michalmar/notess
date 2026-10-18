import Foundation

/// Resolves the target of a Wiki-link (`[[Note]]`) to a note in the Vault.
///
/// Notes are found by file name anywhere in the Vault: Journal, Free Notes and
/// `_brain/`. `[[2026-03-14]]` therefore finds the Daily Entry, and a path
/// suffix such as `[[Projekty/Acme]]` narrows the match to that folder.
///
/// Matching ignores case, a trailing `.md` and differences in Unicode
/// normalisation. When several notes share a name, the choice is deterministic:
/// 1. a note whose name matches exactly (same case) beats a case-only match;
/// 2. a Free Note beats a Daily Entry, which beats a Brain Note (the user's own
///    writing wins over the Agent's);
/// 3. the note nearest the Vault root (fewest folders) wins;
/// 4. the path that sorts first (by Unicode scalars, case-insensitive, then
///    case-sensitive) wins.
public struct WikiLinkResolver: Sendable {
    private struct Candidate: Sendable {
        let relativePath: String
        let kindRank: Int
        let depth: Int
        let exactKey: String
        let foldedKey: String
    }

    private let candidates: [Candidate]

    /// - Parameter relativePaths: Vault-relative paths of files; those that are
    ///   not notes (see `NoteKind.classify`) are ignored.
    public init(relativePaths: [String]) {
        candidates = relativePaths.compactMap { path in
            guard let kind = NoteKind.classify(relativePath: path) else { return nil }
            let normalized = path.precomposedStringWithCanonicalMapping
            let withoutExtension = String(normalized.dropLast(3))
            let rank: Int
            switch kind {
            case .freeNote: rank = 0
            case .dailyEntry: rank = 1
            case .brainNote: rank = 2
            }
            return Candidate(
                relativePath: path,
                kindRank: rank,
                depth: path.split(separator: "/").count,
                exactKey: withoutExtension,
                foldedKey: withoutExtension.lowercased()
            )
        }
    }

    /// The Vault-relative path of the note `target` refers to, or nil if there
    /// is none. `target` is the part of a Wiki-link before `#`.
    public func resolve(target: String) -> String? {
        guard let wanted = Self.wanted(target) else { return nil }
        let folded = wanted.lowercased()

        let matches = candidates.filter { candidate in
            candidate.foldedKey == folded
                || candidate.foldedKey.hasSuffix("/" + folded)
        }
        return matches.min(by: { Self.precedes($0, $1, wanted: wanted) })?.relativePath
    }

    /// The key `resolve(target:)` matches notes by, or nil if `target` can
    /// match none. Links with equal keys always resolve to the same note.
    static func matchKey(forTarget target: String) -> String? {
        wanted(target)?.lowercased()
    }

    /// The match keys of all links that may resolve to the note at
    /// `relativePath`: its folded path without `.md` and every shorter
    /// suffix starting after a `/`. Adding or removing that note can only
    /// change where links with one of these keys resolve.
    static func matchKeys(forPath relativePath: String) -> [String] {
        guard NoteKind.classify(relativePath: relativePath) != nil else { return [] }
        let folded = String(relativePath.precomposedStringWithCanonicalMapping.dropLast(3)).lowercased()
        var keys = [folded]
        var rest = Substring(folded)
        while let slash = rest.firstIndex(of: "/") {
            rest = rest[rest.index(after: slash)...]
            keys.append(String(rest))
        }
        return keys
    }

    private static func wanted(_ target: String) -> String? {
        var wanted = target.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping
        if wanted.lowercased().hasSuffix(".md") { wanted = String(wanted.dropLast(3)) }
        while wanted.hasPrefix("/") { wanted.removeFirst() }
        return wanted.isEmpty ? nil : wanted
    }

    private static func precedes(_ a: Candidate, _ b: Candidate, wanted: String) -> Bool {
        let aExact = a.exactKey == wanted || a.exactKey.hasSuffix("/" + wanted)
        let bExact = b.exactKey == wanted || b.exactKey.hasSuffix("/" + wanted)
        if aExact != bExact { return aExact }
        if a.kindRank != b.kindRank { return a.kindRank < b.kindRank }
        if a.depth != b.depth { return a.depth < b.depth }
        if a.foldedKey != b.foldedKey {
            return a.foldedKey.unicodeScalars.lexicographicallyPrecedes(b.foldedKey.unicodeScalars)
        }
        return a.exactKey.unicodeScalars.lexicographicallyPrecedes(b.exactKey.unicodeScalars)
    }
}

extension Vault {
    /// Vault-relative paths of all notes (Journal, Free Notes and `_brain/`),
    /// in no particular order. Hidden items and symbolic links are skipped.
    public func scanNotePaths() -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let prefix = rootURL.resolvingSymlinksInPath().path + "/"
        var paths: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            if NoteKind.classify(relativePath: relative) != nil { paths.append(relative) }
        }
        return paths
    }
}
