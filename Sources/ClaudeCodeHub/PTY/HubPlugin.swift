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

    static func launchConfiguration(sessionID: Int64, workingDir: String) -> Launch {
        guard let plugin = mainPluginDirectory else {
            appLog("[HubPlugin] cch-main plugin not found in bundle; launching claude without core memory")
            return Launch(args: [], environment: [])
        }
        // Allow every tool of the plugin's `cch` server without prompting.
        let serverPermission = String(MemoryTools.toolPrefix.dropLast(2))
        let settings = "{\"permissions\":{\"allow\":[\"\(serverPermission)\"]}}"
        return Launch(
            args: ["--plugin-dir", plugin, "--settings", settings],
            environment: ["CCH_ROLE=main", "CCH_SESSION_ID=\(sessionID)", "CCH_SESSION_DIR=\(workingDir)"]
        )
    }
}
