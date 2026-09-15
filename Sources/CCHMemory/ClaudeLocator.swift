import Foundation

/// Find the `claude` CLI on disk. The user's shell alias isn't visible to a non-login
/// process, so we probe well-known locations before falling back to PATH.
public enum ClaudeLocator {
    public static func findExecutable() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude"
        ]
        let fm = FileManager.default
        for path in candidates {
            if fm.isExecutableFile(atPath: path) { return path }
        }
        // PATH fallback (from our own env, which inherits the launching user's PATH).
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = "\(dir)/claude"
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    /// Build the environment array passed to claude's PTY child.
    /// We start from our own env (which contains PATH, HOME, etc.) and overlay TERM/LANG.
    public static func env(extraPath: String? = nil) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        if let extraPath {
            let current = env["PATH"] ?? ""
            env["PATH"] = "\(extraPath):\(current)"
        }
        return env.map { "\($0.key)=\($0.value)" }
    }
}
