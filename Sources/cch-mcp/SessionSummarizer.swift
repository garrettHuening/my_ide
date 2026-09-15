import CCHMemory
import Darwin
import Foundation

/// Writes the session-continuation memory for one Claude session (spec M5). Runs detached from
/// the hook so Claude never waits on it.
struct SessionSummarizer {
    let store: MemoryStore
    let console: ConsoleLog?

    /// A second snapshot of the same session within this window is skipped (PreCompact + SessionEnd back to back).
    static let lockWindow: TimeInterval = 10 * 60

    func run(sessionID: String, transcriptPath: String, cwd: String, event: String) {
        do {
            guard let contents = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else { return }
            let condensed = TranscriptCondenser.condense(jsonl: contents)
            guard condensed.count >= SessionSnapshot.minimumCharacters else { return }

            let sizeKey = "memory.snapshot.size.\(sessionID)"
            let lockKey = "memory.snapshot.lock.\(sessionID)"
            if try store.pref(sizeKey) == String(contents.utf8.count) { return }
            if let lock = try store.pref(lockKey).flatMap(Double.init),
               Date().timeIntervalSince1970 - lock < Self.lockWindow { return }
            try store.setPref(lockKey, String(Date().timeIntervalSince1970))
            defer { try? store.setPref(lockKey, "0") }

            let resolved = ProjectKey.resolve(directory: cwd)
            let project = try store.project(for: resolved)
            guard let claude = ClaudeLocator.findExecutable() else {
                log(.error, "claude executable not found; no session memory written", project: project.id, session: sessionID)
                return
            }
            let model = try store.backgroundModel()
            let reply = try summarize(claude: claude, model: model, cwd: cwd,
                                      prompt: SessionSnapshot.prompt(condensed: condensed, projectName: project.name))
            guard let memory = try SessionSnapshot.save(store: store, projectID: project.id, sessionID: sessionID,
                                                        projectName: project.name, reply: reply, transcript: contents,
                                                        branch: resolved.branch) else {
                log(.warning, "summarizer reply was empty; no session memory written", project: project.id, session: sessionID)
                return
            }
            try store.setPref(sizeKey, String(contents.utf8.count))
            log(.info, "Saved [M\(memory.id)] \(memory.title) (\(event))", project: project.id, session: sessionID)
        } catch {
            log(.error, "session snapshot failed: \(error)", project: nil, session: sessionID)
        }
    }

    private func summarize(claude: String, model: String, cwd: String, prompt: String) throws -> String {
        let result = HeadlessClaude.run(claude: claude,
                                        arguments: ["-p", "--model", model, "--output-format", "json", "--no-session-persistence",
                                                    "--tools", "", "--strict-mcp-config"],
                                        directory: cwd, stdin: prompt)
        guard result.succeeded else { throw MemoryError.invalid("summarizer failed: \(result.error ?? "unknown")") }
        return result.text
    }

    private func log(_ severity: LogSeverity, _ message: String, project: Int64?, session: String) {
        try? console?.append(domain: "session", severity: severity, source: "cch-mcp", message: message, projectID: project, sessionID: session)
    }
}

enum Detached {
    static var selfPath: String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    /// Starts a process in its own session with stdio on /dev/null, so it outlives the hook.
    static func spawn(executable: String, arguments: [String]) -> Bool {
        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        return posix_spawn(&pid, executable, &actions, &attributes, argv, environ) == 0
    }
}

/// `--name value` pairs.
struct Flags {
    private var values: [String: String] = [:]

    init(_ args: [String]) {
        var index = 0
        while index < args.count {
            if args[index].hasPrefix("--"), index + 1 < args.count {
                values[args[index]] = args[index + 1]
                index += 2
            } else {
                index += 1
            }
        }
    }

    subscript(name: String) -> String? { values[name] }
}
