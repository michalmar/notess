import Foundation
import SQLite3

/// A minimal wrapper around the system SQLite library (with FTS5) used by
/// `SearchIndex`. Not thread-safe: one connection per owner.
final class SQLiteDatabase {
    struct Error: Swift.Error, CustomStringConvertible {
        let code: Int32
        let message: String
        var description: String { "SQLite error \(code): \(message)" }
    }

    enum Value {
        case int(Int64)
        case double(Double)
        case text(String)
        case null
    }

    private let handle: OpaquePointer

    init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(url.path(percentEncoded: false), &handle, flags, nil)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close_v2(handle)
            throw Error(code: code, message: message)
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, 2_000)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard code == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            throw Error(code: code, message: message)
        }
    }

    /// Runs `sql` with `values` bound to its `?` parameters and returns every
    /// row as column values.
    @discardableResult
    func query(_ sql: String, _ values: [Value] = []) throws -> [[Value]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError()
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .int(let int): code = sqlite3_bind_int64(statement, index, int)
            case .double(let double): code = sqlite3_bind_double(statement, index, double)
            case .text(let text): code = sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .null: code = sqlite3_bind_null(statement, index)
            }
            guard code == SQLITE_OK else { throw lastError() }
        }

        var rows: [[Value]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw lastError() }
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: .int(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: .double(sqlite3_column_double(statement, column))
                case SQLITE_NULL: .null
                default: .text(String(cString: sqlite3_column_text(statement, column)))
                }
            })
        }
        return rows
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Runs `body`, stopping it with `CancellationError` once `isCancelled`
    /// returns true: before it starts, or while one of its statements runs
    /// (SQLite polls `isCancelled` every few thousand instructions). Only for
    /// read-only work: an interrupted write would not be rolled back here.
    func cancellable<T>(when isCancelled: @escaping () -> Bool, _ body: () throws -> T) throws -> T {
        if isCancelled() { throw CancellationError() }
        let poll = CancellationPoll(isCancelled)
        sqlite3_progress_handler(handle, 4_000, { context in
            guard let context else { return 0 }
            return Unmanaged<CancellationPoll>.fromOpaque(context).takeUnretainedValue().isCancelled() ? 1 : 0
        }, Unmanaged.passUnretained(poll).toOpaque())
        defer {
            sqlite3_progress_handler(handle, 0, nil, nil)
            withExtendedLifetime(poll) {}
        }
        do {
            return try body()
        } catch let error as Error where error.code == SQLITE_INTERRUPT {
            throw CancellationError()
        }
    }

    private final class CancellationPoll {
        let isCancelled: () -> Bool
        init(_ isCancelled: @escaping () -> Bool) { self.isCancelled = isCancelled }
    }

    private func lastError() -> Error {
        Error(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

extension SQLiteDatabase.Value {
    var int: Int? {
        if case .int(let value) = self { return Int(value) }
        return nil
    }

    var double: Double? {
        switch self {
        case .double(let value): value
        case .int(let value): Double(value)
        default: nil
        }
    }

    var text: String? {
        if case .text(let value) = self { return value }
        return nil
    }
}
