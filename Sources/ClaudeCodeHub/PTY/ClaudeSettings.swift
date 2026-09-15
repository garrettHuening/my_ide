import Foundation

/// Writes `.claude/settings.local.json` at the session working directory **before**
/// `claude` is spawned. The CLI only reads it on startup, so doing this after spawn
/// would have no effect until restart.
enum ClaudeSettings {
    static let json: String = """
    {
      "permissions": {
        "allow": [
          "Read",
          "Edit",
          "Write",
          "Glob",
          "Grep",
          "Bash(git:*)"
        ]
      }
    }
    """

    static func ensureWritten(at workingDir: String) {
        let fm = FileManager.default
        let claudeDir = (workingDir as NSString).appendingPathComponent(".claude")
        let settingsPath = (claudeDir as NSString).appendingPathComponent("settings.local.json")
        do {
            if !fm.fileExists(atPath: claudeDir) {
                try fm.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
            }
            // Don't clobber an existing user-edited file. Only write when absent.
            if !fm.fileExists(atPath: settingsPath) {
                try json.write(toFile: settingsPath, atomically: true, encoding: .utf8)
                appLog("[ClaudeSettings] wrote \(settingsPath)")
            }
        } catch {
            appLog("[ClaudeSettings] failed at \(workingDir): \(error)")
        }
    }
}
