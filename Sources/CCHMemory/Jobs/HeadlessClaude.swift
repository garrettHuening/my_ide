import Foundation

public struct HeadlessResult: Sendable {
    public let succeeded: Bool
    public let costUSD: Double?
    public let text: String
    public let error: String?

    /// The last line of the reply that starts with `prefix` (jobs end with a one-line summary).
    public func summaryLine(prefix: String) -> String {
        text.split(separator: "\n").last(where: { $0.hasPrefix(prefix) }).map(String.init) ?? ""
    }
}

/// Runs `claude -p … --output-format json` for background memory jobs (sweep, dreaming, docs,
/// session summaries) and interprets the JSON result.
public enum HeadlessClaude {
    public static func run(claude: String, arguments: [String], directory: String, environment: [String: String] = [:],
                           stdin: String? = nil, stderrPath: String? = nil) -> HeadlessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let input = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        if let stderrPath {
            FileManager.default.createFile(atPath: stderrPath, contents: nil)
            process.standardError = FileHandle(forWritingAtPath: stderrPath) ?? FileHandle.nullDevice
        } else {
            process.standardError = FileHandle.nullDevice
        }
        let output = Pipe()
        process.standardOutput = output

        do {
            try process.run()
        } catch {
            return HeadlessResult(succeeded: false, costUSD: nil, text: "", error: "could not start claude: \(error)")
        }
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let text = json?["result"] as? String ?? String(data: data, encoding: .utf8) ?? ""
        let succeeded = process.terminationStatus == 0 && (json?["is_error"] as? Bool) == false
        let detail = stderrPath.map { " (stderr: \($0))" } ?? ""
        return HeadlessResult(succeeded: succeeded, costUSD: json?["total_cost_usd"] as? Double, text: text,
                              error: succeeded ? nil : "exit \(process.terminationStatus): \(text.prefix(300))\(detail)")
    }
}

/// Documentation ingestion (M4): docs become `doc` / `api` / `design` memories tagged `source: doc`.
public enum DocsIngestion {
    public static let toolPrefix = "mcp__plugin_cch-docs_cch__"

    public static func prompt(projectName: String, source: String) -> String {
        let p = toolPrefix
        let isURL = source.hasPrefix("http://") || source.hasPrefix("https://")
        return """
        You are Claude Code Hub documentation ingestion for the project "\(projectName)". The working directory is the repository (read-only).

        Documentation source: \(source)
        \(isURL ? "Read it with WebFetch. Follow links to other pages of the same documentation site when they are clearly part of it (at most 25 pages)." : "Read it with Read/Glob (if it is a folder, read the documentation files inside it, at most 40 files).")

        Record what the documentation teaches, searching first with \(p)memory_search so you never duplicate an existing memory. Writes are automatically tagged as documentation-sourced.
        - kind "api": endpoints, functions, parameters, return values, errors, limits, auth.
        - kind "design": intent, rationale, constraints, non-goals.
        - kind "doc": concepts, workflows, setup, deployment and operational steps.
        Put the source (URL or path) at the end of each body. Link each memory to the code memories it describes with \(p)memory_link relation "documents".
        When the documentation contradicts what the code does, check the repository with Read/Grep and call \(p)memory_flag_conflict with a concrete note (docs say X, code does Y). Do not "fix" either side.

        Finish with exactly one line: "Ingested: N api, N design, N doc, N links, N conflicts."
        """
    }

    public static func arguments(prompt: String, pluginDirectory: String, model: String, allowWeb: Bool) -> [String] {
        var allowed = ["Read", "Glob", "Grep", String(toolPrefix.dropLast(2))]
        if allowWeb { allowed.append("WebFetch") }
        return ["-p", prompt, "--plugin-dir", pluginDirectory, "--model", model, "--output-format", "json",
                "--no-session-persistence", "--allowedTools"] + allowed + ["--disallowedTools", "Edit", "Write", "NotebookEdit", "Bash"]
    }
}

extension MemoryStore {
    public func startIngestion(projectID: Int64, source: String) throws -> Int64 {
        try db.run("INSERT INTO ingestions(project_id, source, status, memories_before, started_at) VALUES (?, ?, 'running', ?, ?)",
                   [projectID, source, try activeMemoryCount(projectID: projectID), Date()])
    }

    /// Returns the number of memories added.
    @discardableResult
    public func finishIngestion(id: Int64, projectID: Int64, succeeded: Bool, costUSD: Double?, error: String?) throws -> Int {
        let after = try activeMemoryCount(projectID: projectID)
        try db.run("UPDATE ingestions SET status = ?, memories_after = ?, cost_usd = ?, error = ?, finished_at = ? WHERE id = ?",
                   [succeeded ? "succeeded" : "failed", after, costUSD, error, Date(), id])
        let before = try db.queryOne("SELECT memories_before FROM ingestions WHERE id = ?", [id]) { Int($0.int(0)) } ?? after
        return after - before
    }
}
