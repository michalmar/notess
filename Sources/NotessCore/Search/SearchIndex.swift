import CryptoKit
import Foundation

/// The fulltext index of a Vault's notes, split into `SearchSection`s and
/// stored in SQLite FTS5. Search ignores case and diacritics and matches word
/// prefixes.
///
/// The index is only a cache (ADR 0002): it lives outside the Vault and can be
/// deleted and rebuilt from the files at any time. `synchronize()` catches up
/// with the files on disk by comparing modification dates and sizes, so only
/// changed notes are read again. The `update` methods are explicit
/// invalidations: they read every note in their scope again, whatever its
/// stamp says. All work runs off the main thread on this
/// actor; long runs yield between batches so searches stay responsive.
public actor SearchIndex {
    /// Bump when the schema, the way notes are split into Sections or the way
    /// Tags are extracted (`SearchSection.split`, `MarkdownLineLexer`) changes;
    /// an index with another version is discarded and rebuilt from the files.
    /// File stamps alone cannot notice such a change.
    ///
    /// - 2: Tags in headings of any level mark their Section.
    /// - 3: Sections keep their complete Markdown for the Tag Timeline.
    /// - 4: Tag Timeline spans follow heading hierarchy at every level.
    static let schemaVersion = 4
    private static let batchSize = 50

    public let vault: Vault
    public let databaseURL: URL
    private var database: SQLiteDatabase?
    /// Notes whose last read failed. Their stamp in the cache may still match
    /// the file (an explicit reread failed), so passive catch-up must try them
    /// again. Not persisted: after a restart only a changed stamp triggers a retry.
    private var unreadable: Set<String> = []

    public init(vault: Vault, databaseURL: URL) {
        self.vault = vault
        self.databaseURL = databaseURL
    }

    /// `~/Library/Caches/Notess/SearchIndex/<hash of the Vault path>.sqlite`.
    public static func defaultDatabaseURL(for vault: Vault) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let digest = SHA256.hash(data: Data(vault.rootURL.path(percentEncoded: false).utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return caches.appending(path: "Notess/SearchIndex/\(name).sqlite", directoryHint: .notDirectory)
    }

    // MARK: - Keeping the index in sync

    /// Brings the whole index in line with the Vault on disk (passive catch-up):
    /// a note whose size and modification date match the cache is skipped.
    ///
    /// `relativePaths` are files or folders reported as changed (`""` is the
    /// whole Vault); notes in them are read again whatever their stamps say.
    public func synchronize(rereading relativePaths: Set<String> = []) async throws {
        try await synchronize(scopes: [""], rereading: relativePaths)
    }

    /// Reads the given Vault-relative files or folders (as reported by
    /// `VaultWatcher` or after a save) again, also when their stamps match the
    /// cache; `""` means the whole Vault.
    public func update(relativePaths: Set<String>) async throws {
        let scopes = relativePaths.contains("") ? [""] : relativePaths
        try await synchronize(scopes: scopes, rereading: scopes)
    }

    /// Reads one note again after the app saved it, also when its stamp matches
    /// the cache; a file outside the Vault is ignored.
    public func update(fileAt url: URL) async throws {
        let root = vault.rootURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let file = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard file.count > root.count, file.starts(with: root) else { return }
        try await update(relativePaths: [file.dropFirst(root.count).joined(separator: "/")])
    }

    /// Throws the index away and builds it again from the files.
    public func rebuild() async throws {
        database = nil
        unreadable = []
        Self.removeDatabaseFiles(at: databaseURL)
        try await synchronize()
    }

    private static func isCovered(_ path: String, by scopes: Set<String>) -> Bool {
        scopes.contains { $0.isEmpty || path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Notes under `scopes` are read again if their stamp differs from the
    /// cache or they lie under `rereading` (explicit invalidation).
    private func synchronize(scopes: Set<String>, rereading: Set<String>) async throws {
        let db = try openDatabase()
        var onDisk: [String: NoteFile] = [:]
        for scope in scopes {
            for file in scanNotes(under: scope) { onDisk[file.relativePath] = file }
        }
        let indexed = try indexedStamps(in: db).filter { path, _ in Self.isCovered(path, by: scopes) }

        let removed = indexed.keys.filter { onDisk[$0] == nil }
        let changed = onDisk.values
            .filter {
                indexed[$0.relativePath] != $0.stamp || unreadable.contains($0.relativePath)
                    || Self.isCovered($0.relativePath, by: rereading)
            }
            .sorted { $0.relativePath < $1.relativePath }

        if !removed.isEmpty {
            try db.transaction { for path in removed { try Self.removeSections(of: path, in: db) } }
            unreadable.subtract(removed)
        }
        var failures: [IndexingFailure.File] = []
        for start in stride(from: 0, to: changed.count, by: Self.batchSize) {
            try Task.checkCancellation()
            // `rebuild()` replaced the database while this run was suspended; it rescans everything.
            guard database === db else { return }
            // Sources are read before the transaction, so a note that cannot be
            // read keeps its previous records and stamp instead of losing them.
            let sources = changed[start..<min(start + Self.batchSize, changed.count)]
                .map { file in
                    (file, Self.readSource(at: vault.rootURL.appending(path: file.relativePath, directoryHint: .notDirectory)))
                }
            try db.transaction {
                for (file, source) in sources {
                    switch source {
                    case .text(let text): try Self.index(file, text: text, in: db)
                    case .vanished: try Self.removeSections(of: file.relativePath, in: db)
                    case .failed(let reason): failures.append(.init(relativePath: file.relativePath, reason: reason))
                    }
                }
            }
            for (file, source) in sources {
                if case .failed = source { unreadable.insert(file.relativePath) } else { unreadable.remove(file.relativePath) }
            }
            await Task.yield()
        }
        // The notes that could be read are indexed; the others are tried again
        // by the next catch-up (see `unreadable`).
        if !failures.isEmpty { throw IndexingFailure(files: failures) }
    }

    enum Source: Equatable {
        case text(String)
        /// The file disappeared after it was scanned: a deletion, not an error.
        case vanished
        case failed(String)
    }

    static func readSource(at url: URL) -> Source {
        do {
            return .text(try String(contentsOf: url, encoding: .utf8))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .vanished
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func index(_ file: NoteFile, text raw: String, in db: SQLiteDatabase) throws {
        try Self.removeSections(of: file.relativePath, in: db)
        let text = raw.precomposedStringWithCanonicalMapping
        for section in SearchSection.split(text) {
            let markdown = (text as NSString).substring(with: section.range).trimmingCharacters(in: .newlines)
            try db.query(
                "INSERT INTO sections (path, kind, ordinal, title, markdown) VALUES (?, ?, ?, ?, ?)",
                [.text(file.relativePath), .int(Int64(file.kind.searchIndexCode)), .int(Int64(section.ordinal)),
                 section.title.map { .text($0) } ?? .null, .text(markdown)]
            )
            let id = try db.query("SELECT last_insert_rowid()").first?.first ?? .null
            try db.query(
                "INSERT INTO sections_fts (rowid, title, body) VALUES (?, ?, ?)",
                [id, .text(section.title ?? ""), .text(section.body)]
            )
            for tag in section.tags {
                try db.query("INSERT INTO section_tags (section_id, tag) VALUES (?, ?)", [id, .text(tag)])
            }
        }
        if file.kind == .dailyEntry {
            let string = text as NSString
            let sections = HeadingSection.split(text)
            for section in sections {
                for tag in section.tags {
                    // A tagged ancestor already includes this entire subtree.
                    guard !sections.contains(where: {
                        $0.ordinal < section.ordinal && $0.tags.contains(tag)
                            && NSLocationInRange(section.range.location, $0.range)
                    }) else { continue }
                    try db.query("""
                        INSERT INTO timeline_sections (path, ordinal, title, markdown, tag)
                        VALUES (?, ?, ?, ?, ?)
                        """, [
                            .text(file.relativePath), .int(Int64(section.ordinal)),
                            section.title.map { .text($0) } ?? .null,
                            .text(string.substring(with: section.range).trimmingCharacters(in: .newlines)),
                            .text(tag)
                        ])
                }
            }
        }
        try db.query(
            "INSERT OR REPLACE INTO files (path, modified, size) VALUES (?, ?, ?)",
            [.text(file.relativePath), .double(file.stamp.modified), .int(file.stamp.size)]
        )
    }

    private static func removeSections(of path: String, in db: SQLiteDatabase) throws {
        let ids = "SELECT id FROM sections WHERE path = ?"
        try db.query("DELETE FROM sections_fts WHERE rowid IN (\(ids))", [.text(path)])
        try db.query("DELETE FROM section_tags WHERE section_id IN (\(ids))", [.text(path)])
        try db.query("DELETE FROM sections WHERE path = ?", [.text(path)])
        try db.query("DELETE FROM timeline_sections WHERE path = ?", [.text(path)])
        try db.query("DELETE FROM files WHERE path = ?", [.text(path)])
    }

    private func indexedStamps(in db: SQLiteDatabase) throws -> [String: FileStamp] {
        var stamps: [String: FileStamp] = [:]
        for row in try db.query("SELECT path, modified, size FROM files") {
            guard let path = row[0].text, let modified = row[1].double, let size = row[2].int else { continue }
            stamps[path] = FileStamp(modified: modified, size: Int64(size))
        }
        return stamps
    }

    // MARK: - Searching

    /// Notes with a Section matching `query` in the note kinds of `scope`,
    /// grouped Journal, Notes, Brain: one result per file, shown by its first
    /// matching Section. At most `limit` files per group, counted after
    /// grouping by file, so many matching Sections in one note never hide
    /// other notes. Files are ranked by their best Section; Tag-only queries
    /// list Daily Entries newest first and other notes by path.
    public func search(_ query: SearchQuery, scope: SearchScope = .all, limit: Int = 50) throws -> [SearchResultGroup] {
        guard !query.isEmpty else { return [] }
        let db = try openDatabase()
        let tagFilter = query.tags.map { _ in " AND s.id IN (SELECT section_id FROM section_tags WHERE tag = ?)" }.joined()
        let tagValues = query.tags.map { SQLiteDatabase.Value.text($0) }

        return try scope.kinds.compactMap { kind in
            let kindValue = SQLiteDatabase.Value.int(Int64(kind.searchIndexCode))
            let files: [MatchingFile]
            let previews: [Int64: (title: String?, highlightedTitle: SearchSnippet, snippet: SearchSnippet)]
            if let expression = query.ftsExpression {
                // Files rank by their best Section. MATERIALIZED keeps bm25() in the
                // fulltext query; group_concat keeps no order, so ordinals are sorted later.
                files = try db.query("""
                    WITH hits AS MATERIALIZED (
                        SELECT s.id, s.path, s.ordinal, bm25(sections_fts, 4.0, 1.0) AS rank
                        FROM sections_fts JOIN sections s ON s.id = sections_fts.rowid
                        WHERE sections_fts MATCH ? AND s.kind = ?\(tagFilter)
                    )
                    SELECT path, group_concat(ordinal || ':' || id) FROM hits
                    GROUP BY path ORDER BY MIN(rank), path
                    LIMIT ?
                    """, [.text(expression), kindValue] + tagValues + [.int(Int64(limit))]).compactMap(MatchingFile.init)
                guard !files.isEmpty else { return nil }
                let ids = files.map(\.firstSectionID)
                let rows = try db.query("""
                    SELECT s.id, s.title,
                           highlight(sections_fts, 0, char(2), char(3)),
                           snippet(sections_fts, 1, char(2), char(3), '…', 16)
                    FROM sections_fts JOIN sections s ON s.id = sections_fts.rowid
                    WHERE sections_fts MATCH ? AND sections_fts.rowid IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                    """, [.text(expression)] + ids.map { .int($0) })
                previews = Dictionary(uniqueKeysWithValues: rows.map { row in
                    (row[0].int.map(Int64.init) ?? 0, (
                        row[1].text,
                        SearchSnippet(marked: row[2].text ?? "", start: "\u{2}", end: "\u{3}"),
                        SearchSnippet(marked: row[3].text ?? "", start: "\u{2}", end: "\u{3}")
                    ))
                })
            } else {
                let order = kind == .dailyEntry ? "s.path DESC" : "s.path"
                files = try db.query("""
                    SELECT s.path, group_concat(s.ordinal || ':' || s.id) FROM sections s
                    WHERE s.kind = ?\(tagFilter)
                    GROUP BY s.path ORDER BY \(order)
                    LIMIT ?
                    """, [kindValue] + tagValues + [.int(Int64(limit))]).compactMap(MatchingFile.init)
                guard !files.isEmpty else { return nil }
                let ids = files.map(\.firstSectionID)
                let rows = try db.query("""
                    SELECT s.id, s.title, f.body FROM sections s JOIN sections_fts f ON f.rowid = s.id
                    WHERE s.id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                    """, ids.map { .int($0) })
                let needle = "#" + query.tags[0]
                previews = Dictionary(uniqueKeysWithValues: rows.map { row in
                    let title = row[1].text
                    return (row[0].int.map(Int64.init) ?? 0, (
                        title,
                        SearchSnippet(text: title ?? "", highlighting: needle),
                        SearchSnippet(text: row[2].text ?? "", highlighting: needle)
                    ))
                })
            }
            let results = files.compactMap { file -> SearchResult? in
                guard let preview = previews[file.firstSectionID] else { return nil }
                return SearchResult(
                    relativePath: file.path,
                    kind: kind,
                    ordinal: file.ordinals[0],
                    title: preview.title,
                    highlightedTitle: preview.highlightedTitle,
                    snippet: preview.snippet,
                    matchingOrdinals: file.ordinals,
                    query: query
                )
            }
            return results.isEmpty ? nil : SearchResultGroup(kind: kind, results: results)
        }
    }

    /// A row of the per-file search query: the path and its matching Sections
    /// as `ordinal:id` pairs.
    private struct MatchingFile {
        let path: String
        let ordinals: [Int]
        let firstSectionID: Int64

        init?(_ row: [SQLiteDatabase.Value]) {
            guard let path = row[0].text, let pairs = row[1].text else { return nil }
            let sections = pairs.split(separator: ",").compactMap { pair -> (ordinal: Int, id: Int64)? in
                let parts = pair.split(separator: ":")
                guard parts.count == 2, let ordinal = Int(parts[0]), let id = Int64(parts[1]) else { return nil }
                return (ordinal, id)
            }.sorted { $0.ordinal < $1.ordinal }
            guard let first = sections.first else { return nil }
            self.path = path
            ordinals = sections.map(\.ordinal)
            firstSectionID = first.id
        }
    }

    // MARK: - Tag Timeline

    /// Every Tag of the indexed (saved) Daily Entries once, as normalised names
    /// (`Tag.normalize`) in alphabetical order. Free Notes and Brain Notes do not count.
    public func journalTags() throws -> [String] {
        let db = try openDatabase()
        let rows = try db.query("""
            SELECT DISTINCT t.tag FROM section_tags t JOIN sections s ON s.id = t.section_id
            WHERE s.kind = ?
            """, [.int(Int64(NoteKind.dailyEntry.searchIndexCode))])
        return rows.compactMap { $0[0].text }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - Tag suggestions

    /// The Tag vocabulary: every Tag of the indexed (saved) notes of all kinds
    /// in this Vault once, as normalised names in alphabetical order.
    public func vaultTags() throws -> [String] {
        let db = try openDatabase()
        let rows = try db.query("SELECT DISTINCT t.tag FROM section_tags t JOIN sections s ON s.id = t.section_id")
        return rows.compactMap { $0[0].text }.sorted(by: TagCompletion.sortsBefore)
    }

    /// The Tag completion suggestions for `prefix`: vocabulary names starting
    /// with it (`TagCompletion.candidates(matching:in:)`).
    public func tagSuggestions(matching prefix: String) throws -> [String] {
        TagCompletion.candidates(matching: prefix, in: try vaultTags())
    }

    /// The Tag Timeline of `tag` (with or without `#`, compared like any Tag):
    /// every indexed (saved) Daily Entry Section carrying it, complete, grouped
    /// by Daily Entry date with the newest day first and each day's Sections
    /// in their order in the note. Nothing is left out or shortened.
    public func tagTimeline(for tag: String) throws -> [TagTimelineDay] {
        let db = try openDatabase()
        let rows = try db.query("""
            SELECT path, ordinal, title, markdown FROM timeline_sections WHERE tag = ?
            """, [.text(Tag.normalize(tag))])
        var sectionsByDay: [Day: [TagTimelineSection]] = [:]
        for row in rows {
            guard let path = row[0].text, let day = DailyEntry.day(forRelativePath: path) else { continue }
            sectionsByDay[day, default: []].append(TagTimelineSection(
                relativePath: path,
                ordinal: row[1].int ?? 0,
                title: row[2].text,
                markdown: row[3].text ?? ""
            ))
        }
        return sectionsByDay.keys.sorted(by: >).map { day in
            TagTimelineDay(day: day, sections: sectionsByDay[day]!.sorted { $0.ordinal < $1.ordinal })
        }
    }

    // MARK: - Database

    private func openDatabase() throws -> SQLiteDatabase {
        if let database { return database }
        do {
            database = try Self.makeDatabase(at: databaseURL)
        } catch {
            // A damaged, foreign or outdated file is only a cache: start over.
            Self.removeDatabaseFiles(at: databaseURL)
            database = try Self.makeDatabase(at: databaseURL)
        }
        return database!
    }

    private static func makeDatabase(at url: URL) throws -> SQLiteDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SQLiteDatabase(url: url)
        let version = try db.query("PRAGMA user_version").first?.first?.int ?? 0
        guard version == 0 || version == schemaVersion else { throw OutdatedSchema() }
        try db.execute("""
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            CREATE TABLE IF NOT EXISTS files (
                path TEXT PRIMARY KEY, modified REAL NOT NULL, size INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS sections (
                id INTEGER PRIMARY KEY, path TEXT NOT NULL, kind INTEGER NOT NULL,
                ordinal INTEGER NOT NULL, title TEXT, markdown TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS sections_by_path ON sections (path);
            CREATE TABLE IF NOT EXISTS section_tags (section_id INTEGER NOT NULL, tag TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS section_tags_by_tag ON section_tags (tag);
            CREATE INDEX IF NOT EXISTS section_tags_by_section ON section_tags (section_id);
            CREATE TABLE IF NOT EXISTS timeline_sections (
                path TEXT NOT NULL, ordinal INTEGER NOT NULL, title TEXT,
                markdown TEXT NOT NULL, tag TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS timeline_by_tag ON timeline_sections (tag);
            CREATE INDEX IF NOT EXISTS timeline_by_path ON timeline_sections (path);
            CREATE VIRTUAL TABLE IF NOT EXISTS sections_fts USING fts5 (
                title, body, tokenize = 'unicode61 remove_diacritics 2');
            PRAGMA user_version = \(schemaVersion);
            """)
        return db
    }

    private static func removeDatabaseFiles(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path(percentEncoded: false) + suffix)
        }
    }

    // MARK: - Files

    /// Notes whose sources could not be read during an update. Their previous
    /// index records are kept, and the notes are tried again by the next catch-up.
    public struct IndexingFailure: Error, LocalizedError, Equatable {
        public struct File: Equatable, Sendable {
            public let relativePath: String
            public let reason: String
        }

        public let files: [File]

        public var errorDescription: String? {
            guard let first = files.first else { return nil }
            let rest = files.count > 1 ? " a dalších \(files.count - 1)" : ""
            return "poznámku \(first.relativePath)\(rest) se nepodařilo přečíst (\(first.reason))"
        }
    }

    private struct OutdatedSchema: Error {}

    private struct FileStamp: Equatable {
        let modified: Double
        let size: Int64
    }

    private struct NoteFile {
        let relativePath: String
        let kind: NoteKind
        let stamp: FileStamp
    }

    /// Markdown notes at or below a Vault-relative path, like `Vault.quickOpenFiles()`:
    /// hidden items and symbolic links are skipped.
    private func scanNotes(under scope: String) -> [NoteFile] {
        let fm = FileManager.default
        let root = vault.rootURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        let start = scope.isEmpty ? vault.rootURL : vault.rootURL.appending(path: scope)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                                      .contentModificationDateKey, .fileSizeKey]

        func noteFile(_ url: URL) -> NoteFile? {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            guard path.hasPrefix(rootPrefix) else { return nil }
            let relativePath = String(path.dropFirst(rootPrefix.count))
            guard relativePath.hasSuffix(".md"),
                  !relativePath.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { return nil }
            return NoteFile(
                relativePath: relativePath,
                kind: NoteKind.classify(relativePath: relativePath) ?? .freeNote,
                stamp: FileStamp(
                    modified: values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0,
                    size: Int64(values.fileSize ?? 0)
                )
            )
        }

        if !scope.isEmpty {
            guard let values = try? start.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return [] }
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                return noteFile(start).map { [$0] } ?? []
            }
        }
        guard let enumerator = fm.enumerator(at: start, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }
        return enumerator.compactMap { ($0 as? URL).flatMap(noteFile) }
    }
}

extension NoteKind {
    /// The order of result groups: Journal, Notes, Brain.
    static let searchOrder: [NoteKind] = [.dailyEntry, .freeNote, .brainNote]

    /// Stable number stored in the search index.
    var searchIndexCode: Int {
        switch self {
        case .dailyEntry: 0
        case .freeNote: 1
        case .brainNote: 2
        }
    }
}
