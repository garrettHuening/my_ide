import Foundation

public enum LogSeverity: String, CaseIterable, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}

public struct LogEntry: Equatable, Sendable {
    public let id: Int64
    public let at: Date
    public let domain: String
    public let severity: LogSeverity
    public let source: String
    public let projectID: Int64?
    public let sessionID: String?
    public let message: String
    public let dataJSON: String?
}

/// The single debug console (spec section 4): one log, typed by domain and severity, that the
/// Hub, background jobs, Claude sessions and any external process write to.
public final class ConsoleLog {
    public let db: SQLiteConnection
    public static let retentionDays = 30.0
    public static let maxRows = 200_000

    public init(path: String = MemoryPaths.consoleDatabase) throws {
        db = try SQLiteConnection(path: path)
        try db.exec("""
            CREATE TABLE IF NOT EXISTS log (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                at         REAL NOT NULL,
                domain     TEXT NOT NULL,
                severity   TEXT NOT NULL,
                source     TEXT NOT NULL,
                project_id INTEGER,
                session_id TEXT,
                message    TEXT NOT NULL,
                data_json  TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_log_at ON log(at);
            CREATE INDEX IF NOT EXISTS idx_log_domain ON log(domain, at);
            """)
    }

    @discardableResult
    public func append(domain: String, severity: LogSeverity, source: String, message: String,
                       projectID: Int64? = nil, sessionID: String? = nil, dataJSON: String? = nil) throws -> Int64 {
        let domain = domain.trimmingCharacters(in: .whitespaces)
        guard !domain.isEmpty else { throw MemoryError.invalid("domain must not be empty") }
        return try db.run(
            "INSERT INTO log(at, domain, severity, source, project_id, session_id, message, data_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [Date(), domain, severity.rawValue, source, projectID, sessionID, message, dataJSON]
        )
    }

    public func recent(limit: Int = 500, domains: Set<String>? = nil, minimumSeverity: LogSeverity? = nil,
                       text: String? = nil) throws -> [LogEntry] {
        var clauses: [String] = []
        var binds: [Any?] = []
        if let domains, !domains.isEmpty {
            clauses.append("domain IN (\(Array(repeating: "?", count: domains.count).joined(separator: ",")))")
            binds += domains.sorted().map { $0 as Any? }
        }
        if let minimumSeverity {
            let allowed = LogSeverity.allCases.drop(while: { $0 != minimumSeverity }).map(\.rawValue)
            clauses.append("severity IN (\(Array(repeating: "?", count: allowed.count).joined(separator: ",")))")
            binds += allowed.map { $0 as Any? }
        }
        if let text, !text.isEmpty {
            clauses.append("message LIKE ?")
            binds.append("%\(text)%")
        }
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        var out: [LogEntry] = []
        try db.query("SELECT id, at, domain, severity, source, project_id, session_id, message, data_json FROM log \(whereSQL) ORDER BY id DESC LIMIT ?",
                     binds + [limit]) { row in
            out.append(LogEntry(id: row.int(0), at: row.date(1), domain: row.string(2),
                                severity: LogSeverity(rawValue: row.string(3)) ?? .info, source: row.string(4),
                                projectID: row.intOrNil(5), sessionID: row.stringOrNil(6), message: row.string(7),
                                dataJSON: row.stringOrNil(8)))
        }
        return out
    }

    public func prune(now: Date = Date()) throws {
        try db.run("DELETE FROM log WHERE at < ?", [now.addingTimeInterval(-Self.retentionDays * 86_400)])
        try db.run("DELETE FROM log WHERE id <= (SELECT id FROM log ORDER BY id DESC LIMIT 1 OFFSET ?)", [Self.maxRows])
    }
}
