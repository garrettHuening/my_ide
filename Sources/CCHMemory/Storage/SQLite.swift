import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLiteError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String, String)
    case step(String, String)
    case bind(String)

    public var description: String {
        switch self {
        case .open(let m): return "SQLite open: \(m)"
        case .prepare(let sql, let m): return "SQLite prepare(\(sql.prefix(120))): \(m)"
        case .step(let sql, let m): return "SQLite step(\(sql.prefix(120))): \(m)"
        case .bind(let m): return "SQLite bind: \(m)"
        }
    }

    /// The message SQLite (or a RAISE in a trigger) produced.
    public var message: String {
        switch self {
        case .open(let m), .prepare(_, let m), .step(_, let m), .bind(let m): return m
        }
    }
}

/// Minimal SQLite connection. Memory databases are opened by several short-lived processes
/// (one `cch-mcp` per Claude session, one per hook call), so WAL + busy_timeout matter.
public final class SQLiteConnection {
    private var handle: OpaquePointer?
    public let path: String

    public init(path: String) throws {
        self.path = path
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &h, flags, nil)
        guard rc == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            if let h { sqlite3_close(h) }
            throw SQLiteError.open(msg)
        }
        handle = h
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try exec("PRAGMA foreign_keys=ON;")
        try exec("PRAGMA busy_timeout=5000;")
    }

    deinit {
        if let h = handle { sqlite3_close(h) }
    }

    public func exec(_ sql: String) throws {
        guard let h = handle else { throw SQLiteError.open("closed") }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(h, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(h))
            if let err { sqlite3_free(err) }
            throw SQLiteError.step(sql, m)
        }
    }

    /// Runs `sql` once per row, handing each row to `row`.
    public func query(_ sql: String, _ binds: [Any?] = [], row: (SQLiteRow) throws -> Void) throws {
        let stmt = try SQLiteStatement(sql: sql, connection: try requireHandle())
        defer { stmt.finalize() }
        try stmt.bind(binds)
        while try stmt.step() {
            try row(SQLiteRow(stmt: stmt))
        }
    }

    public func queryOne<T>(_ sql: String, _ binds: [Any?] = [], map: (SQLiteRow) throws -> T) throws -> T? {
        var result: T?
        try query(sql, binds) { row in
            if result == nil { result = try map(row) }
        }
        return result
    }

    /// Executes a write and returns the last inserted rowid.
    @discardableResult
    public func run(_ sql: String, _ binds: [Any?] = []) throws -> Int64 {
        let h = try requireHandle()
        let stmt = try SQLiteStatement(sql: sql, connection: h)
        defer { stmt.finalize() }
        try stmt.bind(binds)
        _ = try stmt.step()
        return sqlite3_last_insert_rowid(h)
    }

    public var changes: Int { Int(sqlite3_changes(handle)) }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE;")
        do {
            let value = try body()
            try exec("COMMIT;")
            return value
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func requireHandle() throws -> OpaquePointer {
        guard let h = handle else { throw SQLiteError.open("closed") }
        return h
    }
}

final class SQLiteStatement {
    private let h: OpaquePointer
    private(set) var raw: OpaquePointer?
    let sql: String

    init(sql: String, connection h: OpaquePointer) throws {
        self.h = h
        self.sql = sql
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &s, nil) == SQLITE_OK, let s else {
            throw SQLiteError.prepare(sql, String(cString: sqlite3_errmsg(h)))
        }
        raw = s
    }

    func finalize() {
        if let raw { sqlite3_finalize(raw) }
        raw = nil
    }

    func bind(_ values: [Any?]) throws {
        guard let s = raw else { return }
        for (idx, value) in values.enumerated() {
            let i = Int32(idx + 1)
            switch value {
            case nil: sqlite3_bind_null(s, i)
            case let v as Int: sqlite3_bind_int64(s, i, Int64(v))
            case let v as Int64: sqlite3_bind_int64(s, i, v)
            case let v as Double: sqlite3_bind_double(s, i, v)
            case let v as Bool: sqlite3_bind_int64(s, i, v ? 1 : 0)
            case let v as String: sqlite3_bind_text(s, i, v, -1, SQLITE_TRANSIENT)
            case let v as Date: sqlite3_bind_double(s, i, v.timeIntervalSince1970)
            case let v as Data:
                _ = v.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(s, i, bytes.baseAddress, Int32(v.count), SQLITE_TRANSIENT)
                }
            default:
                throw SQLiteError.bind("unsupported type at \(i): \(type(of: value))")
            }
        }
    }

    func step() throws -> Bool {
        guard let s = raw else { return false }
        switch sqlite3_step(s) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError.step(sql, String(cString: sqlite3_errmsg(h)))
        }
    }
}

public struct SQLiteRow {
    let stmt: SQLiteStatement

    public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt.raw, i) }
    public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt.raw, i) }
    public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt.raw, i) == SQLITE_NULL }
    public func intOrNil(_ i: Int32) -> Int64? { isNull(i) ? nil : int(i) }
    public func string(_ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt.raw, i) else { return "" }
        return String(cString: c)
    }
    public func stringOrNil(_ i: Int32) -> String? { isNull(i) ? nil : string(i) }
    public func date(_ i: Int32) -> Date { Date(timeIntervalSince1970: double(i)) }
    public func dateOrNil(_ i: Int32) -> Date? { isNull(i) ? nil : date(i) }
    public func data(_ i: Int32) -> Data? {
        guard !isNull(i), let bytes = sqlite3_column_blob(stmt.raw, i) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt.raw, i)))
    }
}
