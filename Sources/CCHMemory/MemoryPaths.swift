import Foundation

public enum MemoryPaths {
    /// `~/Library/Application Support/ClaudeCodeHub`, or `$CCH_SUPPORT_DIR` (tests, dev runs).
    public static var supportDirectory: String {
        if let override = ProcessInfo.processInfo.environment["CCH_SUPPORT_DIR"], !override.isEmpty {
            return override
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ClaudeCodeHub", isDirectory: true).path
    }

    public static var memoryDatabase: String { supportDirectory + "/memory.db" }
    public static var consoleDatabase: String { supportDirectory + "/console.db" }
    public static var memoryFilesDirectory: String { supportDirectory + "/memory/files" }
}
