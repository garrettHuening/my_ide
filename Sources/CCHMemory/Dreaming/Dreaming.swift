import Foundation

/// Dreaming (M6): a periodic background pass that consolidates mutable memories, decides feature
/// version bumps conservatively, and flags doc-vs-code conflicts. Bugs and bug learnings are
/// excluded from candidates and protected by triggers.
public enum Dreaming {
    public static let interval: TimeInterval = 6 * 60 * 60
    public static let candidateLimit = 40
    /// Kinds dreaming may consolidate. Sessions are history; bug learnings are frozen.
    public static let kinds: [MemoryKind] = [.architecture, .feature, .api, .design, .script, .diagram, .doc, .learning]

    /// Due when enabled, the last successful dream is older than `interval` (or never ran),
    /// nothing is running, and memories changed since the last dream.
    public static func isDue(enabled: Bool, lastSucceeded: Date?, runningSince: Date?, changedSinceLast: Int, now: Date) -> Bool {
        guard enabled, changedSinceLast > 0 else { return false }
        if let runningSince, now.timeIntervalSince(runningSince) < 2 * 60 * 60 { return false }
        guard let lastSucceeded else { return true }
        return now.timeIntervalSince(lastSucceeded) >= interval
    }

    public static let conservativeBumpRule = """
    Feature version bumps: call feature_bump_version only when the feature's behavior changed in a way that matters to someone debugging it — a capability added or removed, a changed data flow, persistence format or API contract. Wording edits, added detail, refactors that keep behavior, and bug fixes do NOT bump. When unsure, do not bump. A missed bump only leaves a slightly fuzzy feature description while bug grouping stays correct; an unnecessary bump permanently splits the feature's bug history into fragments that are never merged back.
    """

    public static let toolPrefix = "mcp__plugin_cch-dream_cch__"

    public static func prompt(projectName: String, candidateCount: Int) -> String {
        let p = toolPrefix
        return """
        You are Claude Code Hub dreaming for the project "\(projectName)": a background pass that keeps its core memories unique, current and trustworthy. The working directory is the repository (read-only).

        1. Call \(p)dream_candidates (page through with offset) to see the \(candidateCount) memories that changed since the last dream, each with its related memories and, for features, the last recorded version.
        2. For each candidate decide:
           - Duplicate or overlapping memories: merge the knowledge into the better one with \(p)memory_update, then \(p)memory_supersede the other (old → kept). Never lose a fact while merging.
           - Stale memories: if the code (Read/Grep) shows a memory is out of date, fix it with \(p)memory_update and say why.
           - Missing structure: add \(p)memory_link for obvious part_of / documents / relates_to relations.
           - Documentation-sourced memories that contradict code-sourced ones: verify in the code, then call \(p)memory_flag_conflict with a concrete note (what the doc says vs what the code does).
           - Features: compare the current description with the last recorded version.
        3. \(conservativeBumpRule)

        Never touch bugs or bug learnings (the tools refuse). Prefer doing nothing over speculative edits.
        Finish with exactly one line: "Dreamed: N merged, N updated, N linked, N conflicts, N version bumps."
        """
    }

    public static func arguments(prompt: String, pluginDirectory: String, model: String) -> [String] {
        ["-p", prompt, "--plugin-dir", pluginDirectory, "--model", model, "--output-format", "json",
         "--no-session-persistence", "--allowedTools", "Read", "Glob", "Grep", String(toolPrefix.dropLast(2)),
         "--disallowedTools", "Edit", "Write", "NotebookEdit", "Bash"]
    }
}

public struct DreamCandidate: Sendable {
    public let memory: Memory
    public let related: [Memory]
    public let lastVersion: FeatureVersion?
}

public struct DreamRecord: Equatable, Sendable {
    public let id: Int64
    public let projectID: Int64
    public let status: String
    public let since: Date
    public let startedAt: Date
    public let finishedAt: Date?
}

extension MemoryStore {
    public static let dreamingEnabledKey = "memory.dreaming"

    public func dreamingEnabled() throws -> Bool {
        try pref(Self.dreamingEnabledKey) != "0"
    }

    public func changedMemoryCount(projectID: Int64, since: Date) throws -> Int {
        let kinds = Dreaming.kinds.map { "'\($0.rawValue)'" }.joined(separator: ",")
        return Int(try db.queryOne(
            "SELECT COUNT(*) FROM memories WHERE project_id = ? AND superseded_by IS NULL AND kind IN (\(kinds)) AND updated_at > ?",
            [projectID, since]) { $0.int(0) } ?? 0)
    }

    public func dreamCandidates(projectID: Int64, since: Date, limit: Int = Dreaming.candidateLimit) throws -> [DreamCandidate] {
        let kinds = Dreaming.kinds.map { "'\($0.rawValue)'" }.joined(separator: ",")
        var changed: [Memory] = []
        try db.query(
            "SELECT \(Self.memoryColumns) FROM memories WHERE project_id = ? AND superseded_by IS NULL AND kind IN (\(kinds)) AND updated_at > ? ORDER BY updated_at DESC LIMIT ?",
            [projectID, since, limit]) { changed.append(Self.memory($0)) }

        return try changed.map { memory in
            var relatedIDs = Set(try links(of: memory.id).map { $0.fromID == memory.id ? $0.toID : $0.fromID })
            if let match = FTSQuery.match(for: memory.title + " " + memory.body.prefix(300), limit: 12) {
                relatedIDs.formUnion(try ftsMemories(projectIDs: [projectID], match: match, limit: 6))
            }
            if let vector = embedder?.embed(Self.embeddingText(title: memory.title, body: memory.body)) {
                relatedIDs.formUnion(try vectorMemories(projectIDs: [projectID], vector: vector, limit: 4).map(\.id))
            }
            relatedIDs.remove(memory.id)
            let related = try memories(ids: Array(relatedIDs)).values
                .filter { $0.supersededBy == nil && $0.kind != .bugLearning }
                .sorted { $0.id < $1.id }
            let lastVersion = memory.kind == .feature ? try featureVersions(featureID: memory.id).last : nil
            return DreamCandidate(memory: memory, related: Array(related.prefix(8)), lastVersion: lastVersion)
        }
    }

    /// Records a new feature version from the feature's current description.
    public func bumpFeatureVersion(featureID: Int64, reason: String) throws -> FeatureVersion {
        guard let feature = try memory(id: featureID), feature.kind == .feature else {
            throw MemoryError.invalid("M\(featureID) is not a feature memory")
        }
        if let by = feature.supersededBy { throw MemoryError.superseded(id: featureID, by: by) }
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { throw MemoryError.invalid("a reason is required for a version bump") }
        let last = try featureVersions(featureID: featureID).last
        if let last, last.description == feature.body {
            throw MemoryError.invalid("M\(featureID) has not changed since v\(last.version); no bump")
        }
        let next = (last?.version ?? 0) + 1
        try db.run("INSERT INTO feature_versions(feature_id, version, description, reason, created_at) VALUES (?, ?, ?, ?, ?)",
                   [featureID, next, feature.body, reason, Date()])
        guard let created = try featureVersions(featureID: featureID).last else { throw MemoryError.notFound("version") }
        return created
    }

    public func startDream(projectID: Int64, since: Date, candidates: Int, model: String) throws -> Int64 {
        try db.run("INSERT INTO dreams(project_id, status, since, candidates, model, started_at) VALUES (?, 'running', ?, ?, ?, ?)",
                   [projectID, since, candidates, model, Date()])
    }

    public func finishDream(id: Int64, succeeded: Bool, costUSD: Double?, summary: String?, error: String?) throws {
        try db.run("UPDATE dreams SET status = ?, cost_usd = ?, summary = ?, error = ?, finished_at = ? WHERE id = ?",
                   [succeeded ? "succeeded" : "failed", costUSD, summary, error, Date(), id])
    }

    public func lastDream(projectID: Int64, status: String) throws -> DreamRecord? {
        try db.queryOne(
            "SELECT id, project_id, status, since, started_at, finished_at FROM dreams WHERE project_id = ? AND status = ? ORDER BY started_at DESC LIMIT 1",
            [projectID, status]) { row in
            DreamRecord(id: row.int(0), projectID: row.int(1), status: row.string(2), since: row.date(3),
                        startedAt: row.date(4), finishedAt: row.dateOrNil(5))
        }
    }
}
