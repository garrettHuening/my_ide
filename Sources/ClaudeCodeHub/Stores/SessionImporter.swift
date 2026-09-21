import Foundation
import Combine

/// Scans the user's chosen "Claude code session directory" and imports one
/// session per subfolder. Two layouts are supported, auto-detected per entry:
///
/// 1. **Claude state directory** (e.g. `~/.claude/projects/`) — each subfolder
///    is named with `/` and other non-alphanumeric chars in the project's real
///    working dir replaced by `-`, prefixed with `-`. We decode by walking the
///    filesystem.
/// 2. **Project root** (e.g. `~/Documents/Code/`) — each subfolder is a
///    real project directory. The working_dir is just the subfolder's path.
final class SessionImporter: ObservableObject {
    private let prefs: PrefsStore
    private let sessions: SessionStore

    @Published var lastImportedCount: Int?
    @Published var lastError: String?
    @Published var lastRunAt: Date?

    init(prefs: PrefsStore, sessions: SessionStore) {
        self.prefs = prefs
        self.sessions = sessions
        sessions.visibleSourceDir = prefs.claudeStateDir
    }

    @discardableResult
    func scan() -> Int {
        let dir = prefs.claudeStateDir
        sessions.visibleSourceDir = dir
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir) else {
            lastError = "Directory does not exist: \(dir)"
            appLog("[Importer] dir missing: \(dir)")
            return 0
        }

        let url = URL(fileURLWithPath: dir)
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            lastError = "Read \(dir) failed: \(error.localizedDescription)"
            appLog("[Importer] read \(dir) failed: \(error)")
            return 0
        }

        var workingDirs = Set<String>()
        var inputs: [SessionStore.NewSession] = []
        for entry in contents {
            let name = entry.lastPathComponent
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if name.hasPrefix(".") { continue }

            let resolvedWorkingDir: String
            if name.hasPrefix("-") {
                // Claude-encoded
                resolvedWorkingDir = Self.decodeProjectName(name)
            } else {
                // Literal subfolder is the project
                resolvedWorkingDir = entry.path
            }

            if let reason = ImportedPathFilter.skipReason(for: resolvedWorkingDir) {
                appLog("[Importer] skip system path: \(resolvedWorkingDir) (\(reason))")
                continue
            }
            if Self.isExistingFile(resolvedWorkingDir) {
                appLog("[Importer] skip system path: \(resolvedWorkingDir) (not a directory)")
                continue
            }

            workingDirs.insert(resolvedWorkingDir)
            inputs.append(SessionStore.NewSession(
                name: (resolvedWorkingDir as NSString).lastPathComponent,
                workingDir: resolvedWorkingDir,
                tags: [],
                agentFile: nil,
                initialPrompt: nil,
                source: .imported,
                importedFrom: dir
            ))
        }

        // Drop previous-source imports so the sidebar stays scoped to current dir.
        sessions.purgeImportsNotFrom(dir)
        // Rows an older build imported before the filter above existed (BUG-1).
        // Done on every scan rather than as a one-shot migration so that later
        // additions to the rule clean up after themselves too.
        let purged = sessions.purgeImports { session in
            ImportedPathFilter.skipReason(for: session.workingDir) != nil
                || Self.isExistingFile(session.workingDir)
        }
        if purged > 0 { appLog("[Importer] purged \(purged) filtered import(s)") }

        let added = sessions.importSessions(inputs)
        sessions.markMissing(workingDirs: workingDirs, importedFrom: dir)
        lastImportedCount = added
        lastError = nil
        lastRunAt = Date()
        appLog("[Importer] scanned \(inputs.count), added \(added), state dir=\(dir)")
        return added
    }

    /// True when the path exists but is a plain file. `decodeProjectName` walks
    /// the filesystem segment by segment and happily lands on one, so a dragged
    /// screenshot's `.png` can look like a working directory.
    static func isExistingFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }

    /// Decode Claude's project folder name back to a real path.
    /// `-Users-robertsmith-Documents-Claude-CCH` → `/Users/robertsmith/Documents/Claude/CCH`
    static func decodeProjectName(_ encoded: String) -> String {
        var s = encoded
        if s.hasPrefix("-") { s.removeFirst() }
        let segs = s.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        let fm = FileManager.default

        var path = "/"
        var i = 0
        while i < segs.count {
            let children: [String] = (try? fm.contentsOfDirectory(atPath: path)) ?? []
            var bestChild: String?
            var bestConsumed = 0
            for child in children {
                let normChild = normalizeForClaudeEncoding(child)
                for j in 1...(segs.count - i) {
                    let candidate = segs[i..<(i + j)].joined(separator: "-")
                    if normChild == normalizeForClaudeEncoding(candidate) {
                        if j > bestConsumed {
                            bestChild = child
                            bestConsumed = j
                        }
                    }
                }
            }
            if let bestChild {
                path = (path == "/" ? "/" : path + "/") + bestChild
                i += bestConsumed
            } else {
                path = (path == "/" ? "/" : path + "/") + segs[i]
                i += 1
            }
        }
        return path
    }

    /// Mirror Claude's encoding: every non-alphanumeric char → "-".
    private static func normalizeForClaudeEncoding(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
            } else {
                out.append("-")
            }
        }
        return out
    }
}
