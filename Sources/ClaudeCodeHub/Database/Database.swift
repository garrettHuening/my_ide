import Foundation
import SQLite3

let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DBError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String, String)
    case step(String, String)
    case bind(String)

    var description: String {
        switch self {
        case .open(let m): return "DB open: \(m)"
        case .prepare(let sql, let m): return "DB prepare(\(sql)): \(m)"
        case .step(let sql, let m): return "DB step(\(sql)): \(m)"
        case .bind(let m): return "DB bind: \(m)"
        }
    }
}

final class Database {
    private static var sharedInstance: Database?

    static func shared() throws -> Database {
        if let s = sharedInstance { return s }
        let s = try Database()
        sharedInstance = s
        return s
    }

    let dbURL: URL
    private var handle: OpaquePointer?
    private let writeQueue = DispatchQueue(label: "cch.db.write")

    private init() throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ClaudeCodeHub", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.dbURL = dir.appendingPathComponent("app.db")

        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(dbURL.path, &h, flags, nil)
        guard rc == SQLITE_OK, let h else {
            let msg = h.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            if let h { sqlite3_close(h) }
            throw DBError.open(msg)
        }
        self.handle = h
        appLog("[DB] opened \(dbURL.path)")

        // Settings — WAL mode, but explicitly NO mmap because we will fork() later.
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try exec("PRAGMA mmap_size=0;")
        try exec("PRAGMA foreign_keys=ON;")
        try exec("PRAGMA busy_timeout=5000;")

        try Schema.migrate(self)
    }

    deinit {
        if let h = handle { sqlite3_close(h) }
    }

    // MARK: - Low-level

    func exec(_ sql: String) throws {
        guard let h = handle else { throw DBError.open("closed") }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(h, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "rc=\(rc)"
            if let err { sqlite3_free(err) }
            throw DBError.step(sql, m)
        }
    }

    /// Run a write on the serial queue. Use this for any INSERT/UPDATE/DELETE.
    @discardableResult
    func write<T>(_ block: (OpaquePointer) throws -> T) throws -> T {
        try writeQueue.sync {
            guard let h = handle else { throw DBError.open("closed") }
            return try block(h)
        }
    }

    /// Reads can run on the calling thread (SQLITE_OPEN_FULLMUTEX serializes internally).
    func read<T>(_ block: (OpaquePointer) throws -> T) throws -> T {
        guard let h = handle else { throw DBError.open("closed") }
        return try block(h)
    }

    /// Prepare a statement, bind values by ordinal, execute callback per row.
    func query(_ sql: String, _ binds: [Any?] = [], row: (Statement) throws -> Void) throws {
        try read { h in
            let stmt = try Statement(prepare: sql, on: h)
            defer { stmt.finalize() }
            try stmt.bindAll(binds)
            while try stmt.stepRow() {
                try row(stmt)
            }
        }
    }

    @discardableResult
    func writeStatement(_ sql: String, _ binds: [Any?] = []) throws -> Int64 {
        try write { h in
            let stmt = try Statement(prepare: sql, on: h)
            defer { stmt.finalize() }
            try stmt.bindAll(binds)
            _ = try stmt.stepDone()
            return sqlite3_last_insert_rowid(h)
        }
    }
}

// MARK: - Statement wrapper

final class Statement {
    private let h: OpaquePointer
    private var stmt: OpaquePointer?
    let sql: String

    init(prepare sql: String, on h: OpaquePointer) throws {
        self.h = h
        self.sql = sql
        var s: OpaquePointer?
        let rc = sqlite3_prepare_v2(h, sql, -1, &s, nil)
        guard rc == SQLITE_OK, let s else {
            let msg = String(cString: sqlite3_errmsg(h))
            throw DBError.prepare(sql, msg)
        }
        self.stmt = s
    }

    func finalize() {
        if let s = stmt { sqlite3_finalize(s) }
        stmt = nil
    }

    func bindAll(_ values: [Any?]) throws {
        guard let s = stmt else { return }
        for (idx, value) in values.enumerated() {
            let i = Int32(idx + 1)
            switch value {
            case nil:
                sqlite3_bind_null(s, i)
            case let v as Int:
                sqlite3_bind_int64(s, i, Int64(v))
            case let v as Int64:
                sqlite3_bind_int64(s, i, v)
            case let v as Double:
                sqlite3_bind_double(s, i, v)
            case let v as Bool:
                sqlite3_bind_int64(s, i, v ? 1 : 0)
            case let v as String:
                sqlite3_bind_text(s, i, v, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            case let v as Date:
                sqlite3_bind_double(s, i, v.timeIntervalSince1970)
            case let v as Data:
                _ = v.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(s, i, bytes.baseAddress, Int32(v.count), SQLITE_TRANSIENT_DESTRUCTOR)
                }
            default:
                throw DBError.bind("unsupported type for index \(i): \(type(of: value))")
            }
        }
    }

    func stepRow() throws -> Bool {
        guard let s = stmt else { return false }
        let rc = sqlite3_step(s)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default:
            let msg = String(cString: sqlite3_errmsg(h))
            throw DBError.step(sql, msg)
        }
    }

    func stepDone() throws -> Bool {
        guard let s = stmt else { return false }
        let rc = sqlite3_step(s)
        if rc == SQLITE_DONE || rc == SQLITE_ROW { return true }
        let msg = String(cString: sqlite3_errmsg(h))
        throw DBError.step(sql, msg)
    }

    // Column accessors (0-indexed)
    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func bool(_ i: Int32) -> Bool { sqlite3_column_int64(stmt, i) != 0 }
    func string(_ i: Int32) -> String {
        guard let cstr = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: cstr)
    }
    func stringOrNil(_ i: Int32) -> String? {
        if sqlite3_column_type(stmt, i) == SQLITE_NULL { return nil }
        guard let cstr = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: cstr)
    }
    func date(_ i: Int32) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(stmt, i))
    }
}
