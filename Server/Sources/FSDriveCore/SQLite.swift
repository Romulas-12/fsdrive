import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

public struct SQLiteError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { "sqlite: \(message)" }
}

public enum SQLValue {
    case int(Int64)
    case text(String)
    case blob(Data)
    case null
}

extension SQLValue {
    public static func of(_ v: Int64?) -> SQLValue { v.map { .int($0) } ?? .null }
    public static func of(_ v: String?) -> SQLValue { v.map { .text($0) } ?? .null }
    public static func of(_ v: Data?) -> SQLValue { v.map { .blob($0) } ?? .null }
}

public struct SQLRow {
    let stmt: OpaquePointer

    public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    public func optInt(_ i: Int32) -> Int64? { isNull(i) ? nil : int(i) }

    public func text(_ i: Int32) -> String {
        guard let p = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: p)
    }

    public func optText(_ i: Int32) -> String? { isNull(i) ? nil : text(i) }

    public func blob(_ i: Int32) -> Data {
        let n = Int(sqlite3_column_bytes(stmt, i))
        guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return Data() }
        return Data(bytes: p, count: n)
    }

    public func optBlob(_ i: Int32) -> Data? { isNull(i) ? nil : blob(i) }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal SQLite wrapper over the system library. Not thread-safe: callers serialize
/// access (the server keeps it inside an actor).
public final class SQLiteDB {
    private let db: OpaquePointer
    private var cache: [String: OpaquePointer] = [:]

    public init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw SQLiteError(message: "cannot open \(path)")
        }
        db = handle
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON;")
    }

    deinit {
        for stmt in cache.values { sqlite3_finalize(stmt) }
        sqlite3_close_v2(db)
    }

    private var errorMessage: String { String(cString: sqlite3_errmsg(db)) }

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw SQLiteError(message: msg)
        }
    }

    private func statement(_ sql: String, _ args: [SQLValue]) throws -> OpaquePointer {
        let stmt: OpaquePointer
        if let cached = cache[sql] {
            stmt = cached
        } else {
            var p: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &p, nil) == SQLITE_OK, let p else {
                throw SQLiteError(message: "\(errorMessage) in: \(sql)")
            }
            cache[sql] = p
            stmt = p
        }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                v.withUnsafeBytes { raw in
                    _ = sqlite3_bind_blob(stmt, idx, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
                }
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    public func run(_ sql: String, _ args: [SQLValue] = []) throws {
        let stmt = try statement(sql, args)
        defer { sqlite3_reset(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteError(message: "\(errorMessage) in: \(sql)")
        }
    }

    public func query(_ sql: String, _ args: [SQLValue] = [], _ row: (SQLRow) throws -> Void) throws {
        let stmt = try statement(sql, args)
        defer { sqlite3_reset(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError(message: "\(errorMessage) in: \(sql)") }
            try row(SQLRow(stmt: stmt))
        }
    }

    public func first<T>(_ sql: String, _ args: [SQLValue] = [], _ map: (SQLRow) throws -> T) throws -> T? {
        var result: T?
        try query(sql, args) { row in
            if result == nil { result = try map(row) }
        }
        return result
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(db) }
    public var changes: Int { Int(sqlite3_changes(db)) }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}
