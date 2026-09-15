import Foundation

/// memory.db schema. Append-only and frozen rules are enforced here with triggers, so no
/// caller (tool, dreaming job, or a bug in our own code) can rewrite bug history.
enum MemorySchema {
    static let currentVersion = 2

    static func migrate(_ db: SQLiteConnection) throws {
        try db.exec("CREATE TABLE IF NOT EXISTS schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        let version = try db.queryOne("SELECT value FROM schema_meta WHERE key='version'") { Int($0.string(0)) ?? 0 } ?? 0
        if version < 1 {
            try db.transaction {
                try db.exec(v1)
                try db.run("INSERT OR REPLACE INTO schema_meta(key, value) VALUES('version', '1')")
            }
        }
        if version < 2 {
            try db.transaction {
                try db.exec(v2)
                try db.run("INSERT OR REPLACE INTO schema_meta(key, value) VALUES('version', '2')")
            }
        }
    }

    private static let v2 = """
    CREATE TABLE sweeps (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id      INTEGER NOT NULL REFERENCES projects(id),
        commit_sha      TEXT,
        mode            TEXT NOT NULL,
        status          TEXT NOT NULL,
        model           TEXT,
        memories_before INTEGER NOT NULL,
        memories_after  INTEGER,
        cost_usd        REAL,
        error           TEXT,
        started_at      REAL NOT NULL,
        finished_at     REAL
    );
    CREATE INDEX idx_sweeps_project ON sweeps(project_id, started_at);
    """

    private static let v1 = """
    CREATE TABLE projects (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        key         TEXT NOT NULL UNIQUE,
        name        TEXT NOT NULL,
        root        TEXT NOT NULL,
        created_at  REAL NOT NULL
    );

    CREATE TABLE memories (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id      INTEGER NOT NULL REFERENCES projects(id),
        kind            TEXT NOT NULL,
        title           TEXT NOT NULL,
        body            TEXT NOT NULL,
        source          TEXT NOT NULL,
        file_pointer    TEXT,
        branch          TEXT,
        session_id      TEXT,
        bug_id          INTEGER REFERENCES bugs(id),
        content_hash    TEXT NOT NULL,
        embedding       BLOB,
        embedding_model TEXT,
        superseded_by   INTEGER REFERENCES memories(id),
        created_at      REAL NOT NULL,
        updated_at      REAL NOT NULL
    );
    CREATE INDEX idx_memories_project_kind ON memories(project_id, kind);
    CREATE INDEX idx_memories_hash ON memories(project_id, content_hash);

    CREATE VIRTUAL TABLE memories_fts USING fts5(
        title, body, content='memories', content_rowid='id', tokenize='porter unicode61'
    );
    CREATE TRIGGER memories_fts_ai AFTER INSERT ON memories BEGIN
        INSERT INTO memories_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
    END;
    CREATE TRIGGER memories_fts_ad AFTER DELETE ON memories BEGIN
        INSERT INTO memories_fts(memories_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
    END;
    CREATE TRIGGER memories_fts_au AFTER UPDATE OF title, body ON memories BEGIN
        INSERT INTO memories_fts(memories_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
        INSERT INTO memories_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
    END;

    CREATE TRIGGER memories_frozen_no_update BEFORE UPDATE ON memories WHEN old.kind = 'bug-learning' BEGIN
        SELECT RAISE(ABORT, 'bug-learning memories are frozen');
    END;
    CREATE TRIGGER memories_frozen_no_delete BEFORE DELETE ON memories WHEN old.kind = 'bug-learning' BEGIN
        SELECT RAISE(ABORT, 'bug-learning memories are frozen');
    END;

    CREATE TABLE edges (
        from_id     INTEGER NOT NULL REFERENCES memories(id),
        to_id       INTEGER NOT NULL REFERENCES memories(id),
        relation    TEXT NOT NULL,
        created_at  REAL NOT NULL,
        PRIMARY KEY (from_id, to_id, relation)
    );
    CREATE INDEX idx_edges_to ON edges(to_id);

    CREATE TABLE feature_versions (
        feature_id  INTEGER NOT NULL REFERENCES memories(id),
        version     INTEGER NOT NULL,
        description TEXT NOT NULL,
        reason      TEXT NOT NULL,
        created_at  REAL NOT NULL,
        PRIMARY KEY (feature_id, version)
    );

    CREATE TABLE bugs (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id      INTEGER NOT NULL REFERENCES projects(id),
        number          INTEGER NOT NULL,
        title           TEXT NOT NULL,
        symptom         TEXT NOT NULL,
        feature_id      INTEGER REFERENCES memories(id),
        feature_version INTEGER,
        status          TEXT NOT NULL DEFAULT 'open',
        root_cause      TEXT,
        fix_summary     TEXT,
        branch          TEXT,
        commit_sha      TEXT,
        embedding       BLOB,
        created_at      REAL NOT NULL,
        fixed_at        REAL,
        UNIQUE (project_id, number)
    );

    CREATE VIRTUAL TABLE bugs_fts USING fts5(
        title, symptom, root_cause, fix_summary, content='bugs', content_rowid='id', tokenize='porter unicode61'
    );
    CREATE TRIGGER bugs_fts_ai AFTER INSERT ON bugs BEGIN
        INSERT INTO bugs_fts(rowid, title, symptom, root_cause, fix_summary)
        VALUES (new.id, new.title, new.symptom, new.root_cause, new.fix_summary);
    END;
    CREATE TRIGGER bugs_fts_au AFTER UPDATE ON bugs BEGIN
        INSERT INTO bugs_fts(bugs_fts, rowid, title, symptom, root_cause, fix_summary)
        VALUES ('delete', old.id, old.title, old.symptom, old.root_cause, old.fix_summary);
        INSERT INTO bugs_fts(rowid, title, symptom, root_cause, fix_summary)
        VALUES (new.id, new.title, new.symptom, new.root_cause, new.fix_summary);
    END;

    CREATE TRIGGER bugs_no_delete BEFORE DELETE ON bugs BEGIN
        SELECT RAISE(ABORT, 'bugs are append-only');
    END;
    CREATE TRIGGER bugs_single_fix_only BEFORE UPDATE ON bugs
    WHEN NOT (
        old.status = 'open' AND new.status = 'fixed'
        AND new.id = old.id AND new.project_id = old.project_id AND new.number = old.number
        AND new.title = old.title AND new.symptom = old.symptom
        AND new.feature_id IS old.feature_id AND new.feature_version IS old.feature_version
        AND new.created_at = old.created_at AND new.embedding IS old.embedding
    )
    BEGIN
        SELECT RAISE(ABORT, 'bugs are append-only: only one open -> fixed update is allowed');
    END;

    CREATE TABLE bug_links (
        bug_id       INTEGER NOT NULL REFERENCES bugs(id),
        other_bug_id INTEGER NOT NULL REFERENCES bugs(id),
        relation     TEXT NOT NULL,
        created_at   REAL NOT NULL,
        PRIMARY KEY (bug_id, other_bug_id, relation)
    );
    CREATE TRIGGER bug_links_no_delete BEFORE DELETE ON bug_links BEGIN
        SELECT RAISE(ABORT, 'bug links are append-only');
    END;

    CREATE TABLE retrievals (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id  INTEGER,
        session_id  TEXT,
        prompt_hash TEXT NOT NULL,
        memory_ids  TEXT NOT NULL,
        bug_ids     TEXT NOT NULL,
        at          REAL NOT NULL
    );
    CREATE INDEX idx_retrievals_session ON retrievals(session_id, at);

    CREATE TABLE prefs (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );
    """
}
