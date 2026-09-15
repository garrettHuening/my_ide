import Foundation
import Combine

final class PrefsStore: ObservableObject {
    private let db: Database

    enum Key: String {
        case claudeStateDir = "claude_state_dir"
    }

    @Published var claudeStateDir: String

    init(db: Database) {
        self.db = db
        let defaultPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
        self.claudeStateDir = Self.read(db: db, key: .claudeStateDir) ?? defaultPath
        if Self.read(db: db, key: .claudeStateDir) == nil {
            Self.write(db: db, key: .claudeStateDir, value: defaultPath)
        }
    }

    func setClaudeStateDir(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        claudeStateDir = trimmed
        Self.write(db: db, key: .claudeStateDir, value: trimmed)
    }

    // MARK: - Static IO

    private static func read(db: Database, key: Key) -> String? {
        var value: String?
        do {
            try db.query("SELECT value FROM user_prefs WHERE key=? LIMIT 1", [key.rawValue]) { row in
                value = row.string(0)
            }
        } catch {
            appLog("[PrefsStore] read(\(key.rawValue)) failed: \(error)")
        }
        return value
    }

    private static func write(db: Database, key: Key, value: String) {
        do {
            try db.writeStatement("""
                INSERT INTO user_prefs(key,value) VALUES(?, ?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value
            """, [key.rawValue, value])
        } catch {
            appLog("[PrefsStore] write(\(key.rawValue)) failed: \(error)")
        }
    }
}
