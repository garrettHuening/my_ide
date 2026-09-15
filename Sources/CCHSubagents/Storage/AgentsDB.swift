import CCHMemory
import Foundation

public struct MergeGroup: Equatable, Sendable {
    public let id: Int64
    public let sessionID: Int64
    public let name: String
}

public struct StatusReport: Equatable, Sendable {
    public let subagentID: Int64
    public let at: Date
    public let summary: String
    public let done: [String]
    public let next: [String]
}

/// agents.db — subagents, merge groups, status reports and subagent prefs (spec §2).
/// Only cch-agentd writes it.
public final class AgentsDB {
    public let db: SQLiteConnection

    public static var defaultPath: String { MemoryPaths.supportDirectory + "/agents.db" }

    public init(path: String = AgentsDB.defaultPath) throws {
        db = try SQLiteConnection(path: path)
        try migrate()
    }

    private func migrate() throws {
        try db.exec("CREATE TABLE IF NOT EXISTS schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        let version = try db.queryOne("SELECT value FROM schema_meta WHERE key='version'") { Int($0.string(0)) ?? 0 } ?? 0
        guard version < 1 else { return }
        try db.transaction {
            try db.exec("""
                CREATE TABLE merge_groups (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id INTEGER NOT NULL,
                    name TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    UNIQUE(session_id, name)
                );
                CREATE TABLE subagents (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id INTEGER NOT NULL,
                    session_dir TEXT NOT NULL,
                    repo_root TEXT NOT NULL,
                    category TEXT NOT NULL,
                    title TEXT NOT NULL,
                    brief TEXT NOT NULL,
                    model TEXT,
                    state TEXT NOT NULL,
                    merge_substate TEXT,
                    claude_session_id TEXT NOT NULL,
                    worktree_path TEXT NOT NULL,
                    branch TEXT NOT NULL,
                    base_commit TEXT NOT NULL,
                    base_branch TEXT,
                    merge_tip TEXT,
                    merge_group_id INTEGER REFERENCES merge_groups(id),
                    merge_index INTEGER,
                    host_pid INTEGER,
                    host_started_at REAL,
                    resume_count INTEGER NOT NULL DEFAULT 0,
                    last_resume_at REAL,
                    turns_started INTEGER NOT NULL DEFAULT 0,
                    last_report_turn INTEGER NOT NULL DEFAULT -1,
                    last_report_at REAL,
                    note TEXT,
                    archived_hidden INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    completed_at REAL,
                    merged_at REAL,
                    failure_reason TEXT
                );
                CREATE INDEX idx_subagents_session ON subagents(session_id, state);
                CREATE TABLE status_reports (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    subagent_id INTEGER NOT NULL REFERENCES subagents(id),
                    at REAL NOT NULL,
                    summary TEXT NOT NULL,
                    done_json TEXT NOT NULL,
                    next_json TEXT NOT NULL
                );
                CREATE INDEX idx_status_reports_subagent ON status_reports(subagent_id, at);
                CREATE TABLE prefs (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                """)
            try db.run("INSERT OR REPLACE INTO schema_meta(key, value) VALUES('version', '1')")
        }
    }

    // MARK: Subagents

    public func insert(_ s: Subagent) throws -> Int64 {
        let now = Date()
        return try db.run(
            """
            INSERT INTO subagents(session_id, session_dir, repo_root, category, title, brief, model, state, merge_substate,
                                  claude_session_id, worktree_path, branch, base_commit, base_branch, merge_group_id, merge_index,
                                  created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [s.sessionID, s.sessionDir, s.repoRoot, s.category.rawValue, s.title, s.brief, s.model, s.state.rawValue,
             s.mergeSubstate?.rawValue, s.claudeSessionID, s.worktreePath, s.branch, s.baseCommit, s.baseBranch,
             s.mergeGroupID, s.mergeIndex, now, now]
        )
    }

    /// Writes every mutable column of `s` back.
    public func save(_ s: Subagent) throws {
        try db.run(
            """
            UPDATE subagents SET title = ?, brief = ?, model = ?, state = ?, merge_substate = ?, worktree_path = ?, branch = ?,
                base_commit = ?, base_branch = ?, merge_tip = ?, merge_group_id = ?, merge_index = ?, host_pid = ?, host_started_at = ?,
                resume_count = ?, last_resume_at = ?, turns_started = ?, last_report_turn = ?, last_report_at = ?,
                completed_at = ?, merged_at = ?, failure_reason = ?, updated_at = ?
            WHERE id = ?
            """,
            [s.title, s.brief, s.model, s.state.rawValue, s.mergeSubstate?.rawValue, s.worktreePath, s.branch, s.baseCommit,
             s.baseBranch, s.mergeTip, s.mergeGroupID, s.mergeIndex, s.hostPID.map { Int64($0) }, s.hostStartedAt,
             s.resumeCount, s.lastResumeAt, s.turnsStarted, s.lastReportTurn, s.lastReportAt,
             s.completedAt, s.mergedAt, s.failureReason, Date(), s.id]
        )
    }

    public func subagent(id: Int64) throws -> Subagent? {
        try db.queryOne("SELECT \(Self.columns) FROM subagents WHERE id = ?", [id], map: Self.subagent)
    }

    public func subagents(sessionID: Int64? = nil, includeHidden: Bool = true) throws -> [Subagent] {
        var clauses: [String] = []
        var binds: [Any?] = []
        if let sessionID {
            clauses.append("session_id = ?")
            binds.append(sessionID)
        }
        if !includeHidden { clauses.append("archived_hidden = 0") }
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        var out: [Subagent] = []
        try db.query("SELECT \(Self.columns) FROM subagents \(whereSQL) ORDER BY id", binds) { out.append(Self.subagent($0)) }
        return out
    }

    public func setNote(_ id: Int64, _ note: String?) throws {
        try db.run("UPDATE subagents SET note = ?, updated_at = ? WHERE id = ?", [note, Date(), id])
    }

    public func note(_ id: Int64) throws -> String? {
        try db.queryOne("SELECT note FROM subagents WHERE id = ?", [id]) { $0.stringOrNil(0) } ?? nil
    }

    public func hideArchived(sessionID: Int64) throws {
        try db.run("UPDATE subagents SET archived_hidden = 1 WHERE session_id = ? AND state IN ('merged', 'stopped', 'discarded')", [sessionID])
    }

    public func isHidden(_ id: Int64) throws -> Bool {
        try db.queryOne("SELECT archived_hidden FROM subagents WHERE id = ?", [id]) { $0.int(0) != 0 } ?? false
    }

    // MARK: Merge groups

    public func group(sessionID: Int64, name: String, create: Bool) throws -> MergeGroup? {
        if let existing = try db.queryOne("SELECT id, session_id, name FROM merge_groups WHERE session_id = ? AND name = ?", [sessionID, name], map: Self.group) {
            return existing
        }
        guard create else { return nil }
        let id = try db.run("INSERT INTO merge_groups(session_id, name, created_at) VALUES (?, ?, ?)", [sessionID, name, Date()])
        return MergeGroup(id: id, sessionID: sessionID, name: name)
    }

    public func group(id: Int64) throws -> MergeGroup? {
        try db.queryOne("SELECT id, session_id, name FROM merge_groups WHERE id = ?", [id], map: Self.group)
    }

    public func groups(sessionID: Int64) throws -> [MergeGroup] {
        var out: [MergeGroup] = []
        try db.query("SELECT id, session_id, name FROM merge_groups WHERE session_id = ? ORDER BY id", [sessionID]) { out.append(Self.group($0)) }
        return out
    }

    public func members(groupID: Int64) throws -> [Subagent] {
        var out: [Subagent] = []
        try db.query("SELECT \(Self.columns) FROM subagents WHERE merge_group_id = ? ORDER BY merge_index, id", [groupID]) { out.append(Self.subagent($0)) }
        return out
    }

    /// Applies a full numbering from `MergeOrder` to a group.
    public func applyOrder(groupID: Int64, _ order: [Int64: Int]) throws {
        try db.transaction {
            for (id, index) in order {
                try db.run("UPDATE subagents SET merge_group_id = ?, merge_index = ?, updated_at = ? WHERE id = ?", [groupID, index, Date(), id])
            }
        }
    }

    public func removeFromGroup(_ id: Int64) throws {
        try db.run("UPDATE subagents SET merge_group_id = NULL, merge_index = NULL, updated_at = ? WHERE id = ?", [Date(), id])
    }

    // MARK: Status reports

    public func addReport(subagentID: Int64, summary: String, done: [String], next: [String]) throws {
        let doneJSON = String(data: try JSONSerialization.data(withJSONObject: done), encoding: .utf8) ?? "[]"
        let nextJSON = String(data: try JSONSerialization.data(withJSONObject: next), encoding: .utf8) ?? "[]"
        try db.run("INSERT INTO status_reports(subagent_id, at, summary, done_json, next_json) VALUES (?, ?, ?, ?, ?)",
                   [subagentID, Date(), summary, doneJSON, nextJSON])
    }

    public func latestReport(subagentID: Int64) throws -> StatusReport? {
        try db.queryOne("SELECT subagent_id, at, summary, done_json, next_json FROM status_reports WHERE subagent_id = ? ORDER BY id DESC LIMIT 1",
                        [subagentID]) { row in
            func list(_ s: String) -> [String] { (try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String]) ?? [] }
            return StatusReport(subagentID: row.int(0), at: row.date(1), summary: row.string(2), done: list(row.string(3)), next: list(row.string(4)))
        }
    }

    // MARK: Prefs

    public func pref(_ key: String) throws -> String? {
        try db.queryOne("SELECT value FROM prefs WHERE key = ?", [key]) { $0.string(0) }
    }

    public func setPref(_ key: String, _ value: String) throws {
        try db.run("INSERT INTO prefs(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, value])
    }

    public static let autoResumeKey = "subagents.autoResume"

    public func autoResume() throws -> Bool { try pref(Self.autoResumeKey) != "0" }

    public func defaultModel(for category: SubagentCategory) throws -> String? {
        let value = try pref(SubagentModel.prefKey(for: category))?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? nil : value
    }

    // MARK: Mapping

    static let columns = """
        id, session_id, session_dir, repo_root, category, title, brief, model, state, merge_substate, claude_session_id, worktree_path,
        branch, base_commit, base_branch, merge_tip, merge_group_id, merge_index, host_pid, host_started_at, resume_count, last_resume_at,
        turns_started, last_report_turn, last_report_at, created_at, updated_at, completed_at, merged_at, failure_reason
        """

    static func subagent(_ r: SQLiteRow) -> Subagent {
        Subagent(id: r.int(0), sessionID: r.int(1), sessionDir: r.string(2), repoRoot: r.string(3),
                 category: SubagentCategory(rawValue: r.string(4)) ?? .task, title: r.string(5), brief: r.string(6),
                 model: r.stringOrNil(7), state: SubagentState(rawValue: r.string(8)) ?? .failed,
                 mergeSubstate: r.stringOrNil(9).flatMap(MergeSubstate.init(rawValue:)), claudeSessionID: r.string(10),
                 worktreePath: r.string(11), branch: r.string(12), baseCommit: r.string(13), baseBranch: r.stringOrNil(14),
                 mergeTip: r.stringOrNil(15), mergeGroupID: r.intOrNil(16), mergeIndex: r.intOrNil(17).map(Int.init),
                 hostPID: r.intOrNil(18).map { Int32($0) }, hostStartedAt: r.dateOrNil(19), resumeCount: Int(r.int(20)),
                 lastResumeAt: r.dateOrNil(21), turnsStarted: Int(r.int(22)), lastReportTurn: Int(r.int(23)),
                 lastReportAt: r.dateOrNil(24), createdAt: r.date(25), updatedAt: r.date(26), completedAt: r.dateOrNil(27),
                 mergedAt: r.dateOrNil(28), failureReason: r.stringOrNil(29))
    }

    static func group(_ r: SQLiteRow) -> MergeGroup {
        MergeGroup(id: r.int(0), sessionID: r.int(1), name: r.string(2))
    }
}
