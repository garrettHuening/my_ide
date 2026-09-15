import Foundation

public enum SweepMode: String, Sendable {
    case full
    case incremental
}

public enum SweepStatus: String, Sendable {
    case running
    case succeeded
    case failed
}

public struct SweepRecord: Equatable, Sendable {
    public let id: Int64
    public let projectID: Int64
    public let commitSHA: String?
    public let mode: SweepMode
    public let status: SweepStatus
    public let startedAt: Date
    public let finishedAt: Date?
}

public enum SweepDecision: Equatable, Sendable {
    case skip
    case full
    case incremental(sinceCommit: String)
}

/// When a repo sweep runs (spec section 3): first open of a never-swept project, or a
/// change-only sweep once it is 20+ commits or 7+ days behind.
public enum SweepPolicy {
    public static let commitThreshold = 20
    public static let ageThreshold: TimeInterval = 7 * 86_400
    /// A `running` record older than this is treated as abandoned (the app quit mid-sweep).
    public static let staleRunning: TimeInterval = 60 * 60

    public static func decide(lastSucceeded: SweepRecord?, running: SweepRecord?, commitsSinceLast: Int?,
                              autoSweep: Bool, now: Date) -> SweepDecision {
        guard autoSweep else { return .skip }
        if let running, now.timeIntervalSince(running.startedAt) < staleRunning { return .skip }
        guard let last = lastSucceeded else { return .full }
        let behindCommits = (commitsSinceLast ?? 0) >= commitThreshold
        let stale = now.timeIntervalSince(last.finishedAt ?? last.startedAt) >= ageThreshold
        guard behindCommits || stale else { return .skip }
        guard let sha = last.commitSHA else { return .full }
        return .incremental(sinceCommit: sha)
    }
}

extension MemoryStore {
    public static let autoSweepKey = "memory.autoSweep"
    public static let backgroundModelKey = "memory.backgroundModel"
    public static let defaultBackgroundModel = "sonnet"

    public func autoSweep() throws -> Bool {
        try pref(Self.autoSweepKey) != "0"
    }

    public func backgroundModel() throws -> String {
        let value = try pref(Self.backgroundModelKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? Self.defaultBackgroundModel : value
    }

    @discardableResult
    public func startSweep(projectID: Int64, commit: String?, mode: SweepMode, model: String) throws -> Int64 {
        try db.run(
            "INSERT INTO sweeps(project_id, commit_sha, mode, status, model, memories_before, started_at) VALUES (?, ?, ?, 'running', ?, ?, ?)",
            [projectID, commit, mode.rawValue, model, try activeMemoryCount(projectID: projectID), Date()]
        )
    }

    public func finishSweep(id: Int64, projectID: Int64, succeeded: Bool, costUSD: Double?, error: String?) throws {
        try db.run(
            "UPDATE sweeps SET status = ?, memories_after = ?, cost_usd = ?, error = ?, finished_at = ? WHERE id = ?",
            [succeeded ? SweepStatus.succeeded.rawValue : SweepStatus.failed.rawValue,
             try activeMemoryCount(projectID: projectID), costUSD, error, Date(), id]
        )
    }

    public func lastSweep(projectID: Int64, status: SweepStatus) throws -> SweepRecord? {
        try db.queryOne(
            "SELECT id, project_id, commit_sha, mode, status, started_at, finished_at FROM sweeps WHERE project_id = ? AND status = ? ORDER BY started_at DESC LIMIT 1",
            [projectID, status.rawValue]) { row in
            SweepRecord(id: row.int(0), projectID: row.int(1), commitSHA: row.stringOrNil(2),
                        mode: SweepMode(rawValue: row.string(3)) ?? .full, status: SweepStatus(rawValue: row.string(4)) ?? .failed,
                        startedAt: row.date(5), finishedAt: row.dateOrNil(6))
        }
    }

    public func sweepMemoriesAdded(sweepID: Int64) throws -> Int? {
        try db.queryOne("SELECT memories_after - memories_before FROM sweeps WHERE id = ?", [sweepID]) { $0.intOrNil(0).map(Int.init) } ?? nil
    }
}

/// A script memory's runnable command: the sweep writes bodies whose first line is `Command: …`.
public enum ScriptCommand {
    public static func command(in body: String) -> String? {
        guard let first = body.split(separator: "\n", omittingEmptySubsequences: true).first else { return nil }
        let line = first.trimmingCharacters(in: .whitespaces)
        guard line.lowercased().hasPrefix("command:") else { return nil }
        var command = line.dropFirst("command:".count).trimmingCharacters(in: .whitespaces)
        if command.hasPrefix("`") && command.hasSuffix("`") && command.count >= 2 {
            command = String(command.dropFirst().dropLast())
        }
        return command.isEmpty ? nil : command
    }

    /// The body without its `Command:` line.
    public static func description(in body: String) -> String {
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let first = lines.first, command(in: first) != nil { lines.removeFirst() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The prompt and CLI arguments for a headless sweep run.
public enum SweepPrompt {
    /// Tools from the sweep plugin's `cch` server.
    public static let toolPrefix = "mcp__plugin_cch-sweep_cch__"

    public static func arguments(prompt: String, pluginDirectory: String, model: String) -> [String] {
        [
            "-p", prompt,
            "--plugin-dir", pluginDirectory,
            "--model", model,
            "--output-format", "json",
            "--no-session-persistence",
            "--allowedTools", "Read", "Glob", "Grep", "Bash(git log *)", "Bash(git ls-files *)", "Bash(git show *)",
            String(toolPrefix.dropLast(2)),
            "--disallowedTools", "Edit", "Write", "NotebookEdit"
        ]
    }

    public static func text(mode: SweepDecision, changedFiles: [String]) -> String {
        let p = toolPrefix
        var header = """
        You are the Claude Code Hub repo sweep for the repository in the current working directory. Build core memories so future Claude sessions understand this repo without re-learning it.

        Use \(p)memory_search, \(p)memory_write, \(p)memory_link and \(p)memory_update, plus Read, Glob, Grep and read-only git commands. Never modify files.
        Every memory you write uses source "code". Titles are short and searchable; bodies are concrete (paths, symbols, commands, data flow). Search before writing so you don't create duplicates.
        """
        switch mode {
        case .incremental(let sha):
            let files = changedFiles.prefix(400).joined(separator: "\n")
            header += """


            MODE: incremental. Files changed since the last sweep (commit \(sha)):
            \(files)

            Only add or update memories affected by these files. Prefer \(p)memory_update (reason "sweep: <what changed>") over new memories. Do not rewrite unaffected memories.
            """
        case .full, .skip:
            header += "\n\nMODE: full sweep of the whole repository."
        }
        return header + """


        Work in this order:
        1. Scripts — package.json scripts, Makefile/Justfile/Taskfile targets, files in scripts/ and bin/, top-level *.sh, fastlane lanes, and similar task runners. For each: kind "script", title = the script's name, and the body's FIRST line must be exactly "Command: <exact command to run from the repo root>", followed by what it does and when to use it.
        2. Architecture — modules/targets/packages, entry points, layers, data stores, external services. kind "architecture". Link sub-parts to their parent with relation part_of.
        3. Diagrams — existing diagram files (Mermaid, draw.io, PlantUML, architecture images in docs): kind "diagram" with file_pointer set to the path. Also write one kind "diagram" memory titled "Architecture flowchart" whose body is a Mermaid flowchart of the architecture you found.
        4. Features — user-facing capabilities traced from their entry point (view, command, route, CLI) through the code. kind "feature"; body covers what it does, entry point, main types/files and data flow. Link each feature to its architecture memory with part_of.
        5. Design — conventions and patterns the code actually follows (state, persistence, errors, naming, testing). kind "design".

        Prefer fewer, richer memories: roughly 15–60 for a full sweep depending on repo size. Finish with exactly one line: "Swept: N scripts, N architecture, N diagrams, N features, N design."
        """
    }
}
