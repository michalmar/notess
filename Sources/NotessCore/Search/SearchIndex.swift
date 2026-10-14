import CryptoKit
import Foundation

/// The fulltext index of a Vault's notes, split into `SearchSection`s and
/// stored in SQLite FTS5. Search ignores case and diacritics and matches word
/// prefixes.
///
/// The index is only a cache (ADR 0002): it lives outside the Vault and can be
/// deleted and rebuilt from the files at any time. `synchronize()` catches up
/// with the files on disk by comparing modification dates and sizes, so only
/// changed notes are read again. All work runs off the main thread on this
/// actor; long runs yield between batches so searches stay responsive.
public actor SearchIndex {
    /// Bump when the schema or the way notes are split changes; an index with
    /// another version is discarded and rebuilt.
    static let schemaVersion = 1
    private static let batchSize = 50

    public let vault: Vault
    public let databaseURL: URL
    private var database: SQLiteDatabase?

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

    /// Brings the whole index in line with the Vault on disk.
    public func synchronize() async throws {
        try await synchronize(scopes: [""])
    }

    /// Re-checks the given Vault-relative files or folders (as reported by
    /// `VaultWatcher` or after a save); `""` means the whole Vault.
    public func update(relativePaths: Set<String>) async throws {
        try await synchronize(scopes: relativePaths.contains("") ? [""] : relativePaths)
    }

    /// Re-checks one note after the app saved it; a file outside the Vault is ignored.
    public func update(fileAt url: URL) async throws {
        let root = vault.rootURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let file = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard file.count > root.count, file.starts(with: root) else { return }
        try await update(relativePaths: [file.dropFirst(root.count).joined(separator: "/")])
    }

    /// Throws the index away and builds it again from the files.
    public func rebuild() async throws {
        database = nil
        Self.removeDatabaseFiles(at: databaseURL)
        try await synchronize()
    }

    private func synchronize(scopes: Set<String>) async throws {
        let db = try openDatabase()
        var onDisk: [String: NoteFile] = [:]
        for scope in scopes {
            for file in scanNotes(under: scope) { onDisk[file.relativePath] = file }
        }
        let indexed = try indexedStamps(in: db).filter { path, _ in
            scopes.contains { $0.isEmpty || path == $0 || path.hasPrefix($0 + "/") }
        }

        let removed = indexed.keys.filter { onDisk[$0] == nil }
        let changed = onDisk.values.filter { indexed[$0.relativePath] != $0.stamp }
            .sorted { $0.relativePath < $1.relativePath }

        if !removed.isEmpty {
            try db.transaction { for path in removed { try removeSections(of: path, in: db) } }
        }
        for start in stride(from: 0, to: changed.count, by: Self.batchSize) {
            try Task.checkCancellation()
            // `rebuild()` replaced the database while this run was suspended; it rescans everything.
            guard database === db else { return }
            try db.transaction {
                for file in changed[start..<min(start + Self.batchSize, changed.count)] {
                    try index(file, in: db)
                }
            }
            await Task.yield()
        }
    }

    private func index(_ file: NoteFile, in db: SQLiteDatabase) throws {
        try removeSections(of: file.relativePath, in: db)
        let url = vault.rootURL.appending(path: file.relativePath, directoryHint: .notDirectory)
        let text = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").precomposedStringWithCanonicalMapping
        for section in SearchSection.split(text) {
            try db.query(
                "INSERT INTO sections (path, kind, ordinal, title) VALUES (?, ?, ?, ?)",
                [.text(file.relativePath), .int(Int64(file.kind.code)), .int(Int64(section.ordinal)),
                 section.title.map { .text($0) } ?? .null]
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
        try db.query(
            "INSERT OR REPLACE INTO files (path, modified, size) VALUES (?, ?, ?)",
            [.text(file.relativePath), .double(file.stamp.modified), .int(file.stamp.size)]
        )
    }

    private func removeSections(of path: String, in db: SQLiteDatabase) throws {
        let ids = "SELECT id FROM sections WHERE path = ?"
        try db.query("DELETE FROM sections_fts WHERE rowid IN (\(ids))", [.text(path)])
        try db.query("DELETE FROM section_tags WHERE section_id IN (\(ids))", [.text(path)])
        try db.query("DELETE FROM sections WHERE path = ?", [.text(path)])
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

    /// Sections matching `query`, grouped Journal, Notes, Brain; at most
    /// `limit` per group, best matches first. Tag-only queries list Journal
    /// Sections newest first.
    public func search(_ query: SearchQuery, limit: Int = 50) throws -> [SearchResultGroup] {
        guard !query.isEmpty else { return [] }
        let db = try openDatabase()
        let tagFilter = query.tags.map { _ in " AND s.id IN (SELECT section_id FROM section_tags WHERE tag = ?)" }.joined()
        let tagValues = query.tags.map { SQLiteDatabase.Value.text($0) }

        return try NoteKind.searchOrder.compactMap { kind in
            let results: [SearchResult]
            if let expression = query.ftsExpression {
                let rows = try db.query("""
                    SELECT s.path, s.ordinal, s.title,
                           highlight(sections_fts, 0, char(2), char(3)),
                           snippet(sections_fts, 1, char(2), char(3), '…', 16)
                    FROM sections_fts JOIN sections s ON s.id = sections_fts.rowid
                    WHERE sections_fts MATCH ? AND s.kind = ?\(tagFilter)
                    ORDER BY bm25(sections_fts, 4.0, 1.0), s.path, s.ordinal
                    LIMIT ?
                    """, [.text(expression), .int(Int64(kind.code))] + tagValues + [.int(Int64(limit))])
                results = rows.map { row in
                    SearchResult(
                        relativePath: row[0].text ?? "",
                        kind: kind,
                        ordinal: row[1].int ?? 0,
                        title: row[2].text,
                        highlightedTitle: SearchSnippet(marked: row[3].text ?? "", start: "\u{2}", end: "\u{3}"),
                        snippet: SearchSnippet(marked: row[4].text ?? "", start: "\u{2}", end: "\u{3}")
                    )
                }
            } else {
                let order = kind == .dailyEntry ? "s.path DESC" : "s.path"
                let rows = try db.query("""
                    SELECT s.path, s.ordinal, s.title, f.body
                    FROM sections s JOIN sections_fts f ON f.rowid = s.id
                    WHERE s.kind = ?\(tagFilter)
                    ORDER BY \(order), s.ordinal
                    LIMIT ?
                    """, [.int(Int64(kind.code))] + tagValues + [.int(Int64(limit))])
                results = rows.map { row in
                    let title = row[2].text
                    return SearchResult(
                        relativePath: row[0].text ?? "",
                        kind: kind,
                        ordinal: row[1].int ?? 0,
                        title: title,
                        highlightedTitle: SearchSnippet(text: title ?? "", highlighting: "#" + query.tags[0]),
                        snippet: SearchSnippet(text: row[3].text ?? "", highlighting: "#" + query.tags[0])
                    )
                }
            }
            return results.isEmpty ? nil : SearchResultGroup(kind: kind, results: results)
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
                ordinal INTEGER NOT NULL, title TEXT);
            CREATE INDEX IF NOT EXISTS sections_by_path ON sections (path);
            CREATE TABLE IF NOT EXISTS section_tags (section_id INTEGER NOT NULL, tag TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS section_tags_by_tag ON section_tags (tag);
            CREATE INDEX IF NOT EXISTS section_tags_by_section ON section_tags (section_id);
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
    var code: Int {
        switch self {
        case .dailyEntry: 0
        case .freeNote: 1
        case .brainNote: 2
        }
    }
}
