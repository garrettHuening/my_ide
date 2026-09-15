import Foundation
import Combine

enum SessionStoreError: Error, CustomStringConvertible {
    case missingName
    case missingWorkingDir
    var description: String {
        switch self {
        case .missingName: return "Session name is required."
        case .missingWorkingDir: return "Working directory is required."
        }
    }
}

final class SessionStore: ObservableObject {
    private let db: Database

    @Published private(set) var sessions: [Session] = []
    @Published var activeSessionID: Int64?
    @Published var visibleSourceDir: String?   // when set, sidebar filters imports to this source

    var activeSession: Session? {
        guard let id = activeSessionID else { return nil }
        return sessions.first(where: { $0.id == id })
    }

    /// Sessions to display in the sidebar: all manual sessions plus imports
    /// matching the current `visibleSourceDir` (or all imports if unset).
    var displayedSessions: [Session] {
        guard let src = visibleSourceDir else { return sessions }
        return sessions.filter { s in
            s.source == .manual || s.importedFrom == src
        }
    }

    init(db: Database) {
        self.db = db
        reload()
        activeSessionID = displayedSessions.first?.id
    }

    // MARK: - Reads

    func reload() {
        do {
            var rows: [Session] = []
            try db.query("""
                SELECT id, name, working_dir, tags, agent_file, initial_prompt,
                       status, created_at, updated_at, last_opened_at,
                       folder_id, sort_order, has_pending_action, source, missing, imported_from,
                       is_favorite
                FROM sessions
                ORDER BY COALESCE(folder_id, 0), sort_order ASC, updated_at DESC
            """) { row in
                rows.append(Self.decode(row))
            }
            self.sessions = rows
            // Keep activeSessionID valid against the *displayed* slice.
            let displayed = displayedSessions
            if let active = activeSessionID, !displayed.contains(where: { $0.id == active }) {
                activeSessionID = displayed.first?.id
            }
        } catch {
            appLog("[SessionStore] reload failed: \(error)")
        }
    }

    // MARK: - Writes

    struct NewSession {
        var name: String
        var workingDir: String
        var tags: [String]
        var agentFile: String?
        var initialPrompt: String?
        var source: SessionSource = .manual
        var importedFrom: String? = nil
    }

    /// Creates or, on UNIQUE working_dir collision, switches to the existing session.
    @discardableResult
    func createOrSwitch(_ input: NewSession) throws -> Session {
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let dir = input.workingDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SessionStoreError.missingName }
        guard !dir.isEmpty else { throw SessionStoreError.missingWorkingDir }

        if !FileManager.default.fileExists(atPath: dir) && input.source != .imported {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        if let existing = lookupByWorkingDir(dir) {
            // If this is an import for a different source, retag it so the
            // filter keeps it visible from the new origin too.
            if input.source == .imported, existing.importedFrom != input.importedFrom {
                try db.writeStatement(
                    "UPDATE sessions SET imported_from=?, source='imported', updated_at=? WHERE id=?",
                    [input.importedFrom, Date(), existing.id]
                )
            }
            reload()
            appLog("[SessionStore] retagged/switched existing session id=\(existing.id) dir=\(dir)")
            return existing
        }

        let now = Date()
        let tagsStr = Session.tagsString(input.tags)
        let nextOrder = nextSortOrder(folderID: nil)
        let id = try db.writeStatement("""
            INSERT INTO sessions(name, working_dir, tags, agent_file, initial_prompt,
                                 status, created_at, updated_at, last_opened_at,
                                 folder_id, sort_order, has_pending_action, source, missing, imported_from)
            VALUES (?, ?, ?, ?, ?, 'stopped', ?, ?, ?, NULL, ?, 0, ?, 0, ?)
        """, [name, dir, tagsStr, input.agentFile, input.initialPrompt,
              now, now, now, nextOrder, input.source.rawValue, input.importedFrom])
        appLog("[SessionStore] inserted session id=\(id) name=\(name) dir=\(dir) source=\(input.source.rawValue) from=\(input.importedFrom ?? "-")")
        reload()
        return sessions.first(where: { $0.id == id })!
    }

    /// Bulk-create from importer. Returns count of newly inserted sessions.
    @discardableResult
    func importSessions(_ inputs: [NewSession]) -> Int {
        var added = 0
        for input in inputs {
            let preexisting = lookupByWorkingDir(input.workingDir) != nil
            do {
                _ = try createOrSwitch(input)
                if !preexisting { added += 1 }
            } catch {
                appLog("[SessionStore] import skip \(input.workingDir): \(error)")
            }
        }
        return added
    }

    /// Remove imported sessions whose source directory is no longer the active one
    /// (i.e., leftovers from a previous import target). Manual sessions are preserved.
    func purgeImportsNotFrom(_ activeSourceDir: String) {
        do {
            try db.writeStatement(
                "DELETE FROM sessions WHERE source='imported' AND (imported_from IS NULL OR imported_from != ?)",
                [activeSourceDir]
            )
            reload()
        } catch {
            appLog("[SessionStore] purgeImportsNotFrom failed: \(error)")
        }
    }

    func rename(_ id: Int64, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try db.writeStatement(
                "UPDATE sessions SET name=?, updated_at=? WHERE id=?",
                [trimmed, Date(), id]
            )
            reload()
        } catch {
            appLog("[SessionStore] rename failed: \(error)")
        }
    }

    func delete(_ id: Int64) {
        do {
            try db.writeStatement("DELETE FROM sessions WHERE id=?", [id])
            if activeSessionID == id { activeSessionID = nil }
            reload()
        } catch {
            appLog("[SessionStore] delete failed: \(error)")
        }
    }

    func moveToFolder(_ sessionID: Int64, folderID: Int64?) {
        let nextOrder = nextSortOrder(folderID: folderID)
        do {
            try db.writeStatement(
                "UPDATE sessions SET folder_id=?, sort_order=?, updated_at=? WHERE id=?",
                [folderID, nextOrder, Date(), sessionID]
            )
            reload()
        } catch {
            appLog("[SessionStore] moveToFolder failed: \(error)")
        }
    }

    func setSessionSortOrder(_ sessionID: Int64, _ newOrder: Double) {
        do {
            try db.writeStatement(
                "UPDATE sessions SET sort_order=?, updated_at=? WHERE id=?",
                [newOrder, Date(), sessionID]
            )
            reload()
        } catch {
            appLog("[SessionStore] setSessionSortOrder failed: \(error)")
        }
    }

    func switchTo(_ id: Int64) {
        activeSessionID = id
        touchLastOpened(id)
        reload()
    }

    func markAllStopped() {
        do {
            try db.writeStatement("UPDATE sessions SET status='stopped' WHERE status != 'stopped'", [])
            reload()
        } catch {
            appLog("[SessionStore] markAllStopped failed: \(error)")
        }
    }

    func setStatus(_ id: Int64, _ status: SessionStatus) {
        do {
            try db.writeStatement(
                "UPDATE sessions SET status=?, updated_at=? WHERE id=?",
                [status.rawValue, Date(), id]
            )
            reload()
        } catch {
            appLog("[SessionStore] setStatus failed: \(error)")
        }
    }

    /// The Claude conversation this session resumes on relaunch; created on first use.
    func claudeSessionID(for id: Int64) -> (id: String, isNew: Bool) {
        var existing: String?
        try? db.query("SELECT claude_session_id FROM sessions WHERE id = ?", [id]) { row in
            existing = row.stringOrNil(0)
        }
        if let existing, !existing.isEmpty { return (existing, false) }
        let fresh = UUID().uuidString.lowercased()
        do {
            try db.writeStatement("UPDATE sessions SET claude_session_id = ? WHERE id = ?", [fresh, id])
        } catch {
            appLog("[SessionStore] claudeSessionID save failed: \(error)")
        }
        return (fresh, true)
    }

    func toggleFavorite(_ id: Int64) {
        guard let current = sessions.first(where: { $0.id == id }) else { return }
        do {
            try db.writeStatement("UPDATE sessions SET is_favorite=? WHERE id=?", [current.isFavorite ? 0 : 1, id])
            reload()
        } catch {
            appLog("[SessionStore] toggleFavorite failed: \(error)")
        }
    }

    func setPendingAction(_ id: Int64, _ pending: Bool) {
        do {
            try db.writeStatement(
                "UPDATE sessions SET has_pending_action=?, updated_at=? WHERE id=?",
                [pending ? 1 : 0, Date(), id]
            )
            reload()
        } catch {
            appLog("[SessionStore] setPendingAction failed: \(error)")
        }
    }

    func markMissing(workingDirs: Set<String>, importedFrom: String) {
        do {
            for s in sessions where s.source == .imported && s.importedFrom == importedFrom {
                let isMissing = !workingDirs.contains(s.workingDir)
                if s.missing != isMissing {
                    try db.writeStatement(
                        "UPDATE sessions SET missing=?, updated_at=? WHERE id=?",
                        [isMissing ? 1 : 0, Date(), s.id]
                    )
                }
            }
            reload()
        } catch {
            appLog("[SessionStore] markMissing failed: \(error)")
        }
    }

    // MARK: - Helpers

    private func nextSortOrder(folderID: Int64?) -> Double {
        var maxOrder: Double = 0
        let sql: String
        let binds: [Any?]
        if let f = folderID {
            sql = "SELECT COALESCE(MAX(sort_order), 0) FROM sessions WHERE folder_id=?"
            binds = [f]
        } else {
            sql = "SELECT COALESCE(MAX(sort_order), 0) FROM sessions WHERE folder_id IS NULL"
            binds = []
        }
        do {
            try db.query(sql, binds) { row in
                maxOrder = row.double(0)
            }
        } catch {
            appLog("[SessionStore] nextSortOrder: \(error)")
        }
        return maxOrder + 1.0
    }

    private func lookupByWorkingDir(_ dir: String) -> Session? {
        var found: Session?
        do {
            try db.query("""
                SELECT id, name, working_dir, tags, agent_file, initial_prompt,
                       status, created_at, updated_at, last_opened_at,
                       folder_id, sort_order, has_pending_action, source, missing, imported_from,
                       is_favorite
                FROM sessions WHERE working_dir=? LIMIT 1
            """, [dir]) { row in
                found = Self.decode(row)
            }
        } catch {
            appLog("[SessionStore] lookup failed: \(error)")
        }
        return found
    }

    private func touchLastOpened(_ id: Int64) {
        do {
            try db.writeStatement(
                "UPDATE sessions SET last_opened_at=?, updated_at=? WHERE id=?",
                [Date(), Date(), id]
            )
        } catch {
            appLog("[SessionStore] touchLastOpened failed: \(error)")
        }
    }

    private static func decode(_ row: Statement) -> Session {
        let folderIDRaw = row.stringOrNil(10)
        let folderID: Int64? = folderIDRaw.flatMap { Int64($0) }
        return Session(
            id: row.int(0),
            name: row.string(1),
            workingDir: row.string(2),
            tagsRaw: row.string(3),
            agentFile: row.stringOrNil(4),
            initialPrompt: row.stringOrNil(5),
            status: SessionStatus(rawValue: row.string(6)) ?? .stopped,
            createdAt: row.date(7),
            updatedAt: row.date(8),
            lastOpenedAt: row.stringOrNil(9) == nil ? nil : row.date(9),
            folderID: folderID,
            sortOrder: row.double(11),
            hasPendingAction: row.bool(12),
            source: SessionSource(rawValue: row.string(13)) ?? .manual,
            missing: row.bool(14),
            importedFrom: row.stringOrNil(15),
            isFavorite: row.bool(16)
        )
    }
}
