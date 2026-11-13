import Foundation
import SQLite3

struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    var description: String { "SQLite error \(code): \(message)" }
}

enum SQLValue {
    case null
    case int(Int64)
    case real(Double)
    case text(String)

    static func text(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }
    static func int(_ i: Int) -> SQLValue { .int(Int64(i)) }
    static func date(_ d: Date?) -> SQLValue { d.map { .real($0.timeIntervalSince1970) } ?? .null }
}

struct SQLRow {
    fileprivate let stmt: OpaquePointer

    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
    func optText(_ i: Int32) -> String? { isNull(i) ? nil : text(i) }
    /// Empty string means "no value" for dimension columns.
    func dim(_ i: Int32) -> String? { let t = text(i); return t.isEmpty ? nil : t }
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    func real(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func date(_ i: Int32) -> Date? { isNull(i) ? nil : Date(timeIntervalSince1970: real(i)) }
    func decimal(_ i: Int32) -> Decimal { Money.decimal(from: text(i)) ?? 0 }
}

/// A small, careful wrapper over the system SQLite C API: cached prepared statements, transactions,
/// WAL, and `user_version` migrations. Not thread-safe; owned by one actor.
final class SQLiteDatabase {
    private var db: OpaquePointer?
    private var cache = [String: OpaquePointer]()
    private var depth = 0

    private static let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            let code = db.map { sqlite3_errcode($0) } ?? SQLITE_CANTOPEN
            sqlite3_close_v2(db)
            throw SQLiteError(code: code, message: msg)
        }
        sqlite3_busy_timeout(db, 5_000)
        try execute("PRAGMA foreign_keys = ON")
        // In-memory databases ignore WAL; that is fine.
        _ = try query("PRAGMA journal_mode = WAL") { $0.text(0) }
        try execute("PRAGMA synchronous = NORMAL")
    }

    deinit {
        for (_, s) in cache { sqlite3_finalize(s) }
        sqlite3_close_v2(db)
    }

    private func error() -> SQLiteError {
        SQLiteError(code: sqlite3_errcode(db), message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database")
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        if let s = cache[sql] { return s }
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw error() }
        cache[sql] = s
        return s
    }

    private func bind(_ s: OpaquePointer, _ values: [SQLValue]) throws {
        sqlite3_reset(s)
        sqlite3_clear_bindings(s)
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch v {
            case .null: rc = sqlite3_bind_null(s, idx)
            case .int(let n): rc = sqlite3_bind_int64(s, idx, n)
            case .real(let d): rc = sqlite3_bind_double(s, idx, d)
            case .text(let t): rc = sqlite3_bind_text(s, idx, t, -1, Self.transient)
            }
            guard rc == SQLITE_OK else { throw error() }
        }
    }

    func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        let s = try statement(sql)
        try bind(s, values)
        let rc = sqlite3_step(s)
        sqlite3_reset(s)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error() }
    }

    func query<T>(_ sql: String, _ values: [SQLValue] = [], _ map: (SQLRow) throws -> T) throws -> [T] {
        let s = try statement(sql)
        try bind(s, values)
        defer { sqlite3_reset(s) }
        var out = [T]()
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_ROW { out.append(try map(SQLRow(stmt: s))) }
            else if rc == SQLITE_DONE { return out }
            else { throw error() }
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        if depth > 0 { return try body() }
        try execute("BEGIN IMMEDIATE")
        depth += 1
        defer { depth -= 1 }
        do {
            let r = try body()
            try execute("COMMIT")
            return r
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var userVersion: Int {
        get { (try? query("PRAGMA user_version") { $0.int(0) }.first) ?? 0 }
    }

    func setUserVersion(_ v: Int) throws {
        // PRAGMA does not accept bound parameters.
        try execute("PRAGMA user_version = \(v)")
    }

    /// Runs each migration whose index is at or above the stored `user_version`, in one transaction each.
    func migrate(_ migrations: [[String]]) throws {
        let current = userVersion
        guard current <= migrations.count else {
            throw SQLiteError(code: SQLITE_MISMATCH, message: "database is newer (\(current)) than this build (\(migrations.count))")
        }
        for (i, statements) in migrations.enumerated() where i >= current {
            try transaction {
                for sql in statements { try execute(sql) }
                try setUserVersion(i + 1)
            }
        }
    }
}
