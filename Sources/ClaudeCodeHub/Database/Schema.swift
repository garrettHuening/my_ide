import Foundation

enum Schema {
    static let currentVersion: Int64 = 4

    static func migrate(_ db: Database) throws {
        try db.exec("""
            CREATE TABLE IF NOT EXISTS schema_meta (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
        """)

        let version = try currentSchemaVersion(db)
        if version < 1 {
            try migrateToV1(db)
            try setSchemaVersion(db, 1)
            appLog("[DB] migrated to v1")
        }
        if version < 2 {
            try migrateToV2(db)
            try setSchemaVersion(db, 2)
            appLog("[DB] migrated to v2")
        }
        if version < 3 {
            try migrateToV3(db)
            try setSchemaVersion(db, 3)
            appLog("[DB] migrated to v3")
        }
        if version < 4 {
            // The Claude conversation a Hub session resumes on relaunch (spec D11).
            try db.exec("ALTER TABLE sessions ADD COLUMN claude_session_id TEXT;")
            try setSchemaVersion(db, 4)
            appLog("[DB] migrated to v4")
        }
    }

    private static func currentSchemaVersion(_ db: Database) throws -> Int64 {
        var v: Int64 = 0
        try db.query("SELECT value FROM schema_meta WHERE key='version'") { row in
            v = Int64(row.string(0)) ?? 0
        }
        return v
    }

    private static func setSchemaVersion(_ db: Database, _ v: Int64) throws {
        try db.writeStatement(
            "INSERT INTO schema_meta(key,value) VALUES('version', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            ["\(v)"]
        )
    }

    private static func migrateToV1(_ db: Database) throws {
        try db.exec("""
            CREATE TABLE IF NOT EXISTS sessions (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                name         TEXT NOT NULL,
                working_dir  TEXT NOT NULL UNIQUE,
                tags         TEXT NOT NULL DEFAULT '',
                agent_file   TEXT,
                initial_prompt TEXT,
                status       TEXT NOT NULL DEFAULT 'stopped',
                created_at   REAL NOT NULL,
                updated_at   REAL NOT NULL,
                last_opened_at REAL
            );

            CREATE INDEX IF NOT EXISTS idx_sessions_updated ON sessions(updated_at DESC);

            CREATE TABLE IF NOT EXISTS panes (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id   INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                category     TEXT NOT NULL,         -- agent|bug|invest|helper|analyze|manual
                title        TEXT NOT NULL,
                status       TEXT NOT NULL DEFAULT 'draft', -- active|done|draft|open
                log_path     TEXT,
                created_at   REAL NOT NULL,
                updated_at   REAL NOT NULL,
                stack_order  INTEGER NOT NULL DEFAULT 0
            );

            CREATE INDEX IF NOT EXISTS idx_panes_session ON panes(session_id, stack_order);

            CREATE TABLE IF NOT EXISTS plans (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id   INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                name         TEXT NOT NULL,
                file_path    TEXT NOT NULL,
                status       TEXT NOT NULL DEFAULT 'draft', -- draft|in-progress|approved
                created_at   REAL NOT NULL,
                updated_at   REAL NOT NULL,
                UNIQUE(session_id, name)
            );

            CREATE TABLE IF NOT EXISTS tasks (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id   INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                description  TEXT NOT NULL,
                tag          TEXT NOT NULL DEFAULT 'TODO', -- BUG|TODO|INVESTIGATE|PLAN
                status       TEXT NOT NULL DEFAULT 'pending', -- pending|in-progress|completed
                line_no      INTEGER,
                created_at   REAL NOT NULL,
                updated_at   REAL NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_tasks_session ON tasks(session_id, status);

            CREATE TABLE IF NOT EXISTS skills_state (
                source       TEXT NOT NULL,         -- builtin|user|project
                slug         TEXT NOT NULL,
                enabled      INTEGER NOT NULL DEFAULT 1,
                last_seen_at REAL,
                PRIMARY KEY (source, slug)
            );

            CREATE TABLE IF NOT EXISTS agents_state (
                source       TEXT NOT NULL,
                slug         TEXT NOT NULL,
                enabled      INTEGER NOT NULL DEFAULT 1,
                last_seen_at REAL,
                PRIMARY KEY (source, slug)
            );

            CREATE TABLE IF NOT EXISTS mcps_state (
                slug         TEXT PRIMARY KEY,
                enabled      INTEGER NOT NULL DEFAULT 0,
                url          TEXT,
                description  TEXT,
                last_seen_at REAL
            );

            CREATE TABLE IF NOT EXISTS user_prefs (
                key          TEXT PRIMARY KEY,
                value        TEXT NOT NULL
            );
        """)
    }

    private static func migrateToV2(_ db: Database) throws {
        // Folders for organizing sessions, and ordering/pending flag on sessions.
        try db.exec("""
            CREATE TABLE IF NOT EXISTS folders (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                name        TEXT NOT NULL,
                sort_order  REAL NOT NULL DEFAULT 0,
                expanded    INTEGER NOT NULL DEFAULT 1,
                created_at  REAL NOT NULL,
                updated_at  REAL NOT NULL
            );

            ALTER TABLE sessions ADD COLUMN folder_id INTEGER REFERENCES folders(id) ON DELETE SET NULL;
            ALTER TABLE sessions ADD COLUMN sort_order REAL NOT NULL DEFAULT 0;
            ALTER TABLE sessions ADD COLUMN has_pending_action INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE sessions ADD COLUMN source TEXT NOT NULL DEFAULT 'manual';  -- manual|imported
            ALTER TABLE sessions ADD COLUMN missing INTEGER NOT NULL DEFAULT 0;     -- working_dir disappeared

            CREATE INDEX IF NOT EXISTS idx_sessions_folder ON sessions(folder_id, sort_order);
        """)
    }

    private static func migrateToV3(_ db: Database) throws {
        // Tag imported sessions with the source directory they came from.
        // Manual sessions leave this NULL.
        try db.exec("""
            ALTER TABLE sessions ADD COLUMN imported_from TEXT;
            CREATE INDEX IF NOT EXISTS idx_sessions_imported_from ON sessions(imported_from);
        """)
    }
}
