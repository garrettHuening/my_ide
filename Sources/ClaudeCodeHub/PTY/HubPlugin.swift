import Foundation
import CCHMemory

/// The `cch-main` Claude Code plugin shipped inside the app bundle: core-memory hooks and the
/// `cch` MCP server. Passed per launch with `--plugin-dir`, so it only exists in Hub sessions.
enum HubPlugin {
    struct Launch {
        let args: [String]
        let environment: [String]
    }

    static var mainPluginDirectory: String? { pluginDirectory("cch-main") }

    /// Memory tools only, no hooks: used by headless repo sweeps.
    static var sweepPluginDirectory: String? { pluginDirectory("cch-sweep") }
    static var dreamPluginDirectory: String? { pluginDirectory("cch-dream") }
    static var docsPluginDirectory: String? { pluginDirectory("cch-docs") }

    private static func pluginDirectory(_ name: String) -> String? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/plugins/\(name)").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    static func launchConfiguration(sessionID: Int64, workingDir: String, sessions: SessionStore?) -> Launch {
        // Resume this session's previous Hub conversation when its transcript exists (D11).
        var conversation: [String] = []
        if let sessions {
            let claudeSession = sessions.claudeSessionID(for: sessionID)
            conversation = !claudeSession.isNew && transcriptExists(claudeSession.id, workingDir: workingDir)
                ? ["--resume", claudeSession.id]
                : ["--session-id", claudeSession.id]
        }
        guard let plugin = mainPluginDirectory else {
            appLog("[HubPlugin] cch-main plugin not found in bundle; launching claude without core memory")
            return Launch(args: conversation, environment: [])
        }
        // Allow every tool of the plugin's `cch` server without prompting.
        let serverPermission = String(MemoryTools.toolPrefix.dropLast(2))
        let settings = "{\"permissions\":{\"allow\":[\"\(serverPermission)\"]}}"
        return Launch(
            args: conversation + ["--plugin-dir", plugin, "--settings", settings],
            environment: ["CCH_ROLE=main", "CCH_SESSION_ID=\(sessionID)", "CCH_SESSION_DIR=\(workingDir)",
                          "CCH_TOOL_PREFIX=\(MemoryTools.toolPrefix)"]
        )
    }

    /// Claude Code stores transcripts under ~/.claude/projects/<cwd with non-alphanumerics as "-">/<id>.jsonl.
    private static func transcriptExists(_ id: String, workingDir: String) -> Bool {
        let encoded = String(workingDir.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let path = NSHomeDirectory() + "/.claude/projects/\(encoded)/\(id).jsonl"
        return FileManager.default.fileExists(atPath: path)
    }
}
