import CryptoKit
import Foundation

public enum MemoryError: Error, CustomStringConvertible, Equatable {
    case notFound(String)
    case frozen(String)
    case superseded(id: Int64, by: Int64)
    case invalid(String)

    public var description: String {
        switch self {
        case .notFound(let what): return "\(what) not found"
        case .frozen(let what): return "\(what) is frozen and cannot be changed"
        case .superseded(let id, let by): return "M\(id) was superseded by M\(by); update M\(by) instead"
        case .invalid(let why): return why
        }
    }
}

public struct MemoryWriteResult: Equatable, Sendable {
    public let memory: Memory
    public let duplicate: Bool
}

/// All reads and writes of memory.db. Every rule that must hold regardless of caller lives in
/// the schema triggers; this type adds validation with friendlier errors.
public final class MemoryStore {
    public let db: SQLiteConnection
    public let embedder: Embedder?
    public static let duplicateSimilarity: Float = 0.95

    public init(path: String = MemoryPaths.memoryDatabase, embedder: Embedder? = AppleSentenceEmbedder()) throws {
        db = try SQLiteConnection(path: path)
        self.embedder = embedder
        try MemorySchema.migrate(db)
    }

    // MARK: Projects

    public func project(for resolved: ResolvedProject) throws -> Project {
        if let existing = try db.queryOne("SELECT id, key, name, root FROM projects WHERE key = ?", [resolved.key], map: Self.project) {
            return existing
        }
        // The same checkout resolves to a different key once an `origin` is added or removed, so
        // adopt the row already keyed to this root rather than starting a second project. A split
        // strands the memories and orphans the bug ledger permanently: the append-only triggers
        // forbid rewriting bugs.project_id, so those rows can never be moved across.
        if let sameRoot = try db.queryOne("SELECT id, key, name, root FROM projects WHERE root = ? ORDER BY id LIMIT 1",
                                          [resolved.root], map: Self.project) {
            // Only ever upgrade path -> remote. Downgrading would replace the identity every other
            // checkout and worktree of the repo resolves to with a path local to this machine.
            guard ProjectKey.isRemoteKey(resolved.key), !ProjectKey.isRemoteKey(sameRoot.key) else {
                return sameRoot
            }
            try db.run("UPDATE projects SET key = ?, name = ? WHERE id = ?", [resolved.key, resolved.name, sameRoot.id])
            return Project(id: sameRoot.id, key: resolved.key, name: resolved.name, root: sameRoot.root)
        }
        try db.run("INSERT OR IGNORE INTO projects(key, name, root, created_at) VALUES (?, ?, ?, ?)",
                   [resolved.key, resolved.name, resolved.root, Date()])
        guard let created = try db.queryOne("SELECT id, key, name, root FROM projects WHERE key = ?", [resolved.key], map: Self.project) else {
            throw MemoryError.notFound("project \(resolved.key)")
        }
        return created
    }

    public func project(id: Int64) throws -> Project? {
        try db.queryOne("SELECT id, key, name, root FROM projects WHERE id = ?", [id], map: Self.project)
    }

    public func projects() throws -> [Project] {
        var out: [Project] = []
        try db.query("SELECT id, key, name, root FROM projects ORDER BY name") { out.append(Self.project($0)) }
        return out
    }

    // MARK: Memories

    public func writeMemory(
        projectID: Int64,
        kind: MemoryKind,
        title: String,
        body: String,
        source: MemorySource,
        filePointer: String? = nil,
        branch: String? = nil,
        sessionID: String? = nil,
        bugID: Int64? = nil,
        links: [(to: Int64, relation: EdgeRelation)] = []
    ) throws -> MemoryWriteResult {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw MemoryError.invalid("title must not be empty") }
        guard !body.isEmpty else { throw MemoryError.invalid("body must not be empty") }
        for link in links {
            if try memory(id: link.to) == nil { throw MemoryError.notFound("M\(link.to)") }
        }

        let hash = Self.contentHash(kind: kind, title: title, body: body)
        if let existing = try db.queryOne(
            "SELECT \(Self.memoryColumns) FROM memories WHERE project_id = ? AND content_hash = ? AND superseded_by IS NULL",
            [projectID, hash], map: Self.memory) {
            return MemoryWriteResult(memory: existing, duplicate: true)
        }

        let vector = embedder?.embed(Self.embeddingText(title: title, body: body))
        if let vector, !kind.isFrozen,
           let near = try nearestMemory(projectID: projectID, kind: kind, vector: vector),
           near.1 >= Self.duplicateSimilarity,
           let existing = try memory(id: near.0) {
            return MemoryWriteResult(memory: existing, duplicate: true)
        }

        let now = Date()
        let id: Int64 = try db.transaction {
            let id = try db.run(
                """
                INSERT INTO memories(project_id, kind, title, body, source, file_pointer, branch, session_id, bug_id,
                                     content_hash, embedding, embedding_model, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [projectID, kind.rawValue, title, body, source.rawValue, filePointer, branch, sessionID, bugID,
                 hash, vector.map(VectorMath.encode), vector == nil ? nil : embedder?.modelID, now, now]
            )
            if kind == .feature {
                try db.run("INSERT INTO feature_versions(feature_id, version, description, reason, created_at) VALUES (?, 1, ?, 'created', ?)",
                           [id, body, now])
            }
            for link in links {
                try db.run("INSERT OR IGNORE INTO edges(from_id, to_id, relation, created_at) VALUES (?, ?, ?, ?)",
                           [id, link.to, link.relation.rawValue, now])
            }
            return id
        }
        guard let created = try memory(id: id) else { throw MemoryError.notFound("M\(id)") }
        return MemoryWriteResult(memory: created, duplicate: false)
    }

    public func memory(id: Int64) throws -> Memory? {
        try db.queryOne("SELECT \(Self.memoryColumns) FROM memories WHERE id = ?", [id], map: Self.memory)
    }

    public func memories(ids: [Int64]) throws -> [Int64: Memory] {
        guard !ids.isEmpty else { return [:] }
        var out: [Int64: Memory] = [:]
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        try db.query("SELECT \(Self.memoryColumns) FROM memories WHERE id IN (\(placeholders))", ids.map { $0 as Any? }) { row in
            let m = Self.memory(row)
            out[m.id] = m
        }
        return out
    }

    /// Edits a mutable memory in place. Never bumps a feature version (dreaming decides that).
    public func updateMemory(id: Int64, title: String?, body: String?) throws -> Memory {
        guard var current = try memory(id: id) else { throw MemoryError.notFound("M\(id)") }
        guard !current.kind.isFrozen else { throw MemoryError.frozen("M\(id) (\(current.kind.rawValue))") }
        if let by = current.supersededBy { throw MemoryError.superseded(id: id, by: by) }
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { current.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { current.body = body.trimmingCharacters(in: .whitespacesAndNewlines) }
        let vector = embedder?.embed(Self.embeddingText(title: current.title, body: current.body))
        try db.run(
            "UPDATE memories SET title = ?, body = ?, content_hash = ?, embedding = ?, embedding_model = ?, updated_at = ? WHERE id = ?",
            [current.title, current.body, Self.contentHash(kind: current.kind, title: current.title, body: current.body),
             vector.map(VectorMath.encode), vector == nil ? nil : embedder?.modelID, Date(), id]
        )
        guard let updated = try memory(id: id) else { throw MemoryError.notFound("M\(id)") }
        return updated
    }

    public func supersede(_ oldID: Int64, by newID: Int64) throws {
        guard let old = try memory(id: oldID) else { throw MemoryError.notFound("M\(oldID)") }
        guard try memory(id: newID) != nil else { throw MemoryError.notFound("M\(newID)") }
        guard !old.kind.isFrozen else { throw MemoryError.frozen("M\(oldID)") }
        try db.run("UPDATE memories SET superseded_by = ?, updated_at = ? WHERE id = ?", [newID, Date(), oldID])
    }

    public func link(from: Int64, to: Int64, relation: EdgeRelation) throws {
        guard try memory(id: from) != nil else { throw MemoryError.notFound("M\(from)") }
        guard try memory(id: to) != nil else { throw MemoryError.notFound("M\(to)") }
        try db.run("INSERT OR IGNORE INTO edges(from_id, to_id, relation, created_at) VALUES (?, ?, ?, ?)",
                   [from, to, relation.rawValue, Date()])
    }

    /// Links touching `id` in either direction.
    public func links(of id: Int64) throws -> [MemoryLink] {
        var out: [MemoryLink] = []
        try db.query("SELECT from_id, to_id, relation FROM edges WHERE from_id = ? OR to_id = ?", [id, id]) { row in
            if let relation = EdgeRelation(rawValue: row.string(2)) {
                out.append(MemoryLink(fromID: row.int(0), toID: row.int(1), relation: relation))
            }
        }
        return out
    }

    public func activeMemoryCount(projectID: Int64) throws -> Int {
        Int(try db.queryOne("SELECT COUNT(*) FROM memories WHERE project_id = ? AND superseded_by IS NULL", [projectID]) { $0.int(0) } ?? 0)
    }

    public func latestSessionMemory(projectID: Int64) throws -> Memory? {
        try db.queryOne(
            "SELECT \(Self.memoryColumns) FROM memories WHERE project_id = ? AND kind = 'session' AND superseded_by IS NULL ORDER BY updated_at DESC LIMIT 1",
            [projectID], map: Self.memory)
    }

    public func memories(projectID: Int64, kind: MemoryKind) throws -> [Memory] {
        var out: [Memory] = []
        try db.query("SELECT \(Self.memoryColumns) FROM memories WHERE project_id = ? AND kind = ? AND superseded_by IS NULL ORDER BY title",
                     [projectID, kind.rawValue]) { out.append(Self.memory($0)) }
        return out
    }

    // MARK: Features

    public func featureVersions(featureID: Int64) throws -> [FeatureVersion] {
        var out: [FeatureVersion] = []
        try db.query("SELECT feature_id, version, description, reason, created_at FROM feature_versions WHERE feature_id = ? ORDER BY version",
                     [featureID]) { row in
            out.append(FeatureVersion(featureID: row.int(0), version: Int(row.int(1)), description: row.string(2),
                                      reason: row.string(3), createdAt: row.date(4)))
        }
        return out
    }

    public func currentFeatureVersion(featureID: Int64) throws -> Int? {
        try db.queryOne("SELECT MAX(version) FROM feature_versions WHERE feature_id = ?", [featureID]) { $0.intOrNil(0).map(Int.init) } ?? nil
    }

    // MARK: Bugs

    public func openBug(projectID: Int64, title: String, symptom: String, featureID: Int64?, branch: String? = nil) throws -> Bug {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let symptom = symptom.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !symptom.isEmpty else { throw MemoryError.invalid("title and symptom are required") }
        var featureVersion: Int?
        if let featureID {
            guard let feature = try memory(id: featureID), feature.kind == .feature, feature.projectID == projectID else {
                throw MemoryError.invalid("M\(featureID) is not a feature memory in this project")
            }
            featureVersion = try currentFeatureVersion(featureID: featureID)
        }
        let vector = embedder?.embed(Self.embeddingText(title: title, body: symptom))
        let id: Int64 = try db.transaction {
            let next = try db.queryOne("SELECT COALESCE(MAX(number), 0) + 1 FROM bugs WHERE project_id = ?", [projectID]) { $0.int(0) } ?? 1
            return try db.run(
                "INSERT INTO bugs(project_id, number, title, symptom, feature_id, feature_version, branch, embedding, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                [projectID, next, title, symptom, featureID, featureVersion, branch, vector.map(VectorMath.encode), Date()]
            )
        }
        guard let bug = try bug(id: id) else { throw MemoryError.notFound("bug \(id)") }
        return bug
    }

    public func fixBug(projectID: Int64, number: Int, rootCause: String, fixSummary: String, commit: String?) throws -> Bug {
        guard let existing = try bug(projectID: projectID, number: number) else { throw MemoryError.notFound("BUG-\(number)") }
        guard existing.status == .open else { throw MemoryError.frozen("BUG-\(number) (already fixed)") }
        try db.run(
            "UPDATE bugs SET status = 'fixed', root_cause = ?, fix_summary = ?, commit_sha = ?, fixed_at = ? WHERE id = ?",
            [rootCause, fixSummary, commit, Date(), existing.id]
        )
        guard let fixed = try bug(id: existing.id) else { throw MemoryError.notFound("BUG-\(number)") }
        return fixed
    }

    public func addBugLearning(projectID: Int64, number: Int, text: String, sessionID: String?) throws -> Memory {
        guard let bug = try bug(projectID: projectID, number: number) else { throw MemoryError.notFound("BUG-\(number)") }
        let learningCount = try db.queryOne("SELECT COUNT(*) FROM memories WHERE bug_id = ?", [bug.id]) { $0.int(0) } ?? 0
        let result = try writeMemory(projectID: projectID, kind: .bugLearning,
                                     title: "BUG-\(number) learning \(learningCount + 1): \(bug.title)",
                                     body: text, source: .session, sessionID: sessionID, bugID: bug.id)
        return result.memory
    }

    public func linkRegression(projectID: Int64, newNumber: Int, oldNumber: Int) throws {
        guard newNumber != oldNumber else { throw MemoryError.invalid("a bug cannot regress itself") }
        guard let new = try bug(projectID: projectID, number: newNumber) else { throw MemoryError.notFound("BUG-\(newNumber)") }
        guard let old = try bug(projectID: projectID, number: oldNumber) else { throw MemoryError.notFound("BUG-\(oldNumber)") }
        try db.run("INSERT OR IGNORE INTO bug_links(bug_id, other_bug_id, relation, created_at) VALUES (?, ?, 'regression_of', ?)",
                   [new.id, old.id, Date()])
    }

    public func regressions(ofBugID id: Int64) throws -> [Int] {
        var out: [Int] = []
        try db.query("SELECT b.number FROM bug_links l JOIN bugs b ON b.id = l.other_bug_id WHERE l.bug_id = ? ORDER BY b.number", [id]) {
            out.append(Int($0.int(0)))
        }
        return out
    }

    public func bug(projectID: Int64, number: Int) throws -> Bug? {
        try db.queryOne("SELECT \(Self.bugColumns) FROM bugs WHERE project_id = ? AND number = ?", [projectID, number], map: Self.bug)
    }

    public func bug(id: Int64) throws -> Bug? {
        try db.queryOne("SELECT \(Self.bugColumns) FROM bugs WHERE id = ?", [id], map: Self.bug)
    }

    public func bugs(ids: [Int64]) throws -> [Int64: Bug] {
        guard !ids.isEmpty else { return [:] }
        var out: [Int64: Bug] = [:]
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        try db.query("SELECT \(Self.bugColumns) FROM bugs WHERE id IN (\(placeholders))", ids.map { $0 as Any? }) { row in
            let b = Self.bug(row)
            out[b.id] = b
        }
        return out
    }

    public func bugs(featureID: Int64) throws -> [Bug] {
        var out: [Bug] = []
        try db.query("SELECT \(Self.bugColumns) FROM bugs WHERE feature_id = ? ORDER BY created_at DESC", [featureID]) { out.append(Self.bug($0)) }
        return out
    }

    public func bugLearnings(bugID: Int64) throws -> [Memory] {
        var out: [Memory] = []
        try db.query("SELECT \(Self.memoryColumns) FROM memories WHERE bug_id = ? ORDER BY created_at", [bugID]) { out.append(Self.memory($0)) }
        return out
    }

    // MARK: Search primitives

    /// Memory ids ranked by BM25 (best first).
    public func ftsMemories(projectIDs: [Int64]?, match: String, limit: Int) throws -> [Int64] {
        var out: [Int64] = []
        let (clause, binds) = Self.projectClause(projectIDs, column: "m.project_id")
        try db.query(
            """
            SELECT m.id FROM memories_fts f JOIN memories m ON m.id = f.rowid
            WHERE memories_fts MATCH ? AND m.superseded_by IS NULL \(clause)
            ORDER BY bm25(memories_fts, 2.0, 1.0) LIMIT ?
            """,
            [match] + binds + [limit]) { out.append($0.int(0)) }
        return out
    }

    /// Memory ids ranked by cosine similarity to `vector` (best first).
    public func vectorMemories(projectIDs: [Int64]?, vector: [Float], limit: Int) throws -> [(id: Int64, similarity: Float)] {
        var scored: [(Int64, Float)] = []
        let (clause, binds) = Self.projectClause(projectIDs, column: "project_id")
        try db.query("SELECT id, embedding FROM memories WHERE embedding IS NOT NULL AND superseded_by IS NULL \(clause)", binds) { row in
            if let data = row.data(1) {
                scored.append((row.int(0), VectorMath.cosine(vector, VectorMath.decode(data))))
            }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { (id: $0.0, similarity: $0.1) }
    }

    public func ftsBugs(projectIDs: [Int64]?, match: String, limit: Int) throws -> [Int64] {
        var out: [Int64] = []
        let (clause, binds) = Self.projectClause(projectIDs, column: "b.project_id")
        try db.query(
            "SELECT b.id FROM bugs_fts f JOIN bugs b ON b.id = f.rowid WHERE bugs_fts MATCH ? \(clause) ORDER BY bm25(bugs_fts) LIMIT ?",
            [match] + binds + [limit]) { out.append($0.int(0)) }
        return out
    }

    public func vectorBugs(projectIDs: [Int64]?, vector: [Float], limit: Int) throws -> [(id: Int64, similarity: Float)] {
        var scored: [(Int64, Float)] = []
        let (clause, binds) = Self.projectClause(projectIDs, column: "project_id")
        try db.query("SELECT id, embedding FROM bugs WHERE embedding IS NOT NULL \(clause)", binds) { row in
            if let data = row.data(1) {
                scored.append((row.int(0), VectorMath.cosine(vector, VectorMath.decode(data))))
            }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { (id: $0.0, similarity: $0.1) }
    }

    public func bugSimilarity(bugID: Int64, to vector: [Float]) throws -> Float? {
        try db.queryOne("SELECT embedding FROM bugs WHERE id = ?", [bugID]) { row in
            row.data(0).map { VectorMath.cosine(vector, VectorMath.decode($0)) }
        } ?? nil
    }

    /// After a branch merges, its mutable memories belong to the target branch (the promotion
    /// marker merge-gated cloud sync will use). Bugs and bug learnings keep their history.
    @discardableResult
    public func promoteBranch(_ branch: String, to target: String) throws -> Int {
        try db.run("UPDATE memories SET branch = ? WHERE branch = ? AND kind != 'bug-learning'", [target, branch])
        return db.changes
    }

    // MARK: Retrieval log

    public func logRetrieval(projectID: Int64?, sessionID: String?, prompt: String, memoryIDs: [Int64], bugIDs: [Int64]) throws {
        let hash = SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
        try db.run("INSERT INTO retrievals(project_id, session_id, prompt_hash, memory_ids, bug_ids, at) VALUES (?, ?, ?, ?, ?, ?)",
                   [projectID, sessionID, hash, memoryIDs.map(String.init).joined(separator: ","),
                    bugIDs.map(String.init).joined(separator: ","), Date()])
    }

    public func hasRetrievals(sessionID: String) throws -> Bool {
        (try db.queryOne("SELECT 1 FROM retrievals WHERE session_id = ? LIMIT 1", [sessionID]) { _ in true }) ?? false
    }

    /// Number of memories + bugs injected by the most recent retrieval for a session.
    public func lastRetrievalCount(sessionID: String) throws -> Int {
        try db.queryOne("SELECT memory_ids, bug_ids FROM retrievals WHERE session_id = ? ORDER BY at DESC LIMIT 1", [sessionID]) { row in
            [row.string(0), row.string(1)].flatMap { $0.split(separator: ",") }.count
        } ?? 0
    }

    // MARK: Prefs

    public func pref(_ key: String) throws -> String? {
        try db.queryOne("SELECT value FROM prefs WHERE key = ?", [key]) { $0.string(0) }
    }

    public func setPref(_ key: String, _ value: String) throws {
        try db.run("INSERT INTO prefs(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, value])
    }

    public static let strictnessKey = "memory.strictness"

    public func strictness() throws -> GroundingStrictness {
        try pref(Self.strictnessKey).flatMap(GroundingStrictness.init(rawValue:)) ?? .balanced
    }

    public func setStrictness(_ value: GroundingStrictness) throws {
        try setPref(Self.strictnessKey, value.rawValue)
    }

    // MARK: Helpers

    private func nearestMemory(projectID: Int64, kind: MemoryKind, vector: [Float]) throws -> (Int64, Float)? {
        var best: (Int64, Float)?
        try db.query("SELECT id, embedding FROM memories WHERE project_id = ? AND kind = ? AND embedding IS NOT NULL AND superseded_by IS NULL",
                     [projectID, kind.rawValue]) { row in
            guard let data = row.data(1) else { return }
            let sim = VectorMath.cosine(vector, VectorMath.decode(data))
            if best == nil || sim > best!.1 { best = (row.int(0), sim) }
        }
        return best
    }

    static func embeddingText(title: String, body: String) -> String {
        "\(title). \(body)"
    }

    static func contentHash(kind: MemoryKind, title: String, body: String) -> String {
        SHA256.hash(data: Data("\(kind.rawValue)\n\(title)\n\(body)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func projectClause(_ ids: [Int64]?, column: String) -> (String, [Any?]) {
        guard let ids else { return ("", []) }
        guard !ids.isEmpty else { return ("AND 0", []) }
        return ("AND \(column) IN (\(Array(repeating: "?", count: ids.count).joined(separator: ",")))", ids.map { $0 as Any? })
    }

    static let memoryColumns = "id, project_id, kind, title, body, source, file_pointer, branch, session_id, superseded_by, created_at, updated_at"

    static func memory(_ row: SQLiteRow) -> Memory {
        Memory(id: row.int(0), projectID: row.int(1), kind: MemoryKind(rawValue: row.string(2)) ?? .learning,
               title: row.string(3), body: row.string(4), source: MemorySource(rawValue: row.string(5)) ?? .session,
               filePointer: row.stringOrNil(6), branch: row.stringOrNil(7), sessionID: row.stringOrNil(8),
               supersededBy: row.intOrNil(9), createdAt: row.date(10), updatedAt: row.date(11))
    }

    static let bugColumns = "id, project_id, number, title, symptom, feature_id, feature_version, status, root_cause, fix_summary, branch, commit_sha, created_at, fixed_at"

    static func bug(_ row: SQLiteRow) -> Bug {
        Bug(id: row.int(0), projectID: row.int(1), number: Int(row.int(2)), title: row.string(3), symptom: row.string(4),
            featureID: row.intOrNil(5), featureVersion: row.intOrNil(6).map(Int.init),
            status: BugStatus(rawValue: row.string(7)) ?? .open, rootCause: row.stringOrNil(8), fixSummary: row.stringOrNil(9),
            branch: row.stringOrNil(10), commitSHA: row.stringOrNil(11), createdAt: row.date(12), fixedAt: row.dateOrNil(13))
    }

    static func project(_ row: SQLiteRow) -> Project {
        Project(id: row.int(0), key: row.string(1), name: row.string(2), root: row.string(3))
    }
}
