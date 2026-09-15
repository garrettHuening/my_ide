import Foundation
import Combine

final class FolderStore: ObservableObject {
    private let db: Database

    @Published private(set) var folders: [Folder] = []

    init(db: Database) {
        self.db = db
        reload()
    }

    func reload() {
        do {
            var rows: [Folder] = []
            try db.query("""
                SELECT id, name, sort_order, expanded, created_at, updated_at
                FROM folders
                ORDER BY sort_order ASC, id ASC
            """) { row in
                rows.append(Folder(
                    id: row.int(0),
                    name: row.string(1),
                    sortOrder: row.double(2),
                    expanded: row.bool(3),
                    createdAt: row.date(4),
                    updatedAt: row.date(5)
                ))
            }
            folders = rows
        } catch {
            appLog("[FolderStore] reload failed: \(error)")
        }
    }

    @discardableResult
    func create(name: String) -> Folder? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let now = Date()
        let nextOrder = (folders.map { $0.sortOrder }.max() ?? 0) + 1.0
        do {
            let id = try db.writeStatement("""
                INSERT INTO folders(name, sort_order, expanded, created_at, updated_at)
                VALUES (?, ?, 1, ?, ?)
            """, [trimmed, nextOrder, now, now])
            appLog("[FolderStore] created folder id=\(id) name=\(trimmed)")
            reload()
            return folders.first(where: { $0.id == id })
        } catch {
            appLog("[FolderStore] create failed: \(error)")
            return nil
        }
    }

    func rename(_ id: Int64, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try db.writeStatement(
                "UPDATE folders SET name=?, updated_at=? WHERE id=?",
                [trimmed, Date(), id]
            )
            reload()
        } catch {
            appLog("[FolderStore] rename failed: \(error)")
        }
    }

    func delete(_ id: Int64) {
        do {
            // ON DELETE SET NULL on sessions.folder_id moves any sessions back to ungrouped.
            try db.writeStatement("DELETE FROM folders WHERE id=?", [id])
            reload()
        } catch {
            appLog("[FolderStore] delete failed: \(error)")
        }
    }

    func setExpanded(_ id: Int64, _ expanded: Bool) {
        do {
            try db.writeStatement(
                "UPDATE folders SET expanded=?, updated_at=? WHERE id=?",
                [expanded ? 1 : 0, Date(), id]
            )
            reload()
        } catch {
            appLog("[FolderStore] setExpanded failed: \(error)")
        }
    }

    func toggleExpanded(_ id: Int64) {
        guard let f = folders.first(where: { $0.id == id }) else { return }
        setExpanded(id, !f.expanded)
    }

    /// Reorder a folder to a new fractional sort_order.
    func setSortOrder(_ id: Int64, _ newOrder: Double) {
        do {
            try db.writeStatement(
                "UPDATE folders SET sort_order=?, updated_at=? WHERE id=?",
                [newOrder, Date(), id]
            )
            reload()
        } catch {
            appLog("[FolderStore] setSortOrder failed: \(error)")
        }
    }
}
