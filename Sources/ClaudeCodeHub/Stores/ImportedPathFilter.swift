import Foundation

/// Why a working directory found in the Claude state directory does not deserve
/// a session row.
enum ImportSkipReason: String, CustomStringConvertible {
    case root = "filesystem root"
    case home = "home directory"
    case systemDirectory = "system directory"
    case temporary = "temporary directory"

    var description: String { rawValue }
}

/// Decides which decoded working directories the importer keeps out of the
/// sidebar. Pure: no filesystem access, so it is directly testable.
enum ImportedPathFilter {
    struct Environment {
        var home: String
        var temporaryDirectory: String?

        init(home: String = NSHomeDirectory(),
             temporaryDirectory: String? = ProcessInfo.processInfo.environment["TMPDIR"]) {
            self.home = home
            self.temporaryDirectory = temporaryDirectory
        }
    }

    /// Directories that are never a project themselves, but whose children can
    /// be (`/var/www` is a real web root), so these match exactly.
    private static let exactSkips = ["/var"]

    /// Everything at or below these is throwaway. `$TMPDIR` is added at runtime.
    private static let transientPrefixes = ["/tmp", "/var/tmp", "/var/folders"]

    /// macOS parks screenshot and drag-and-drop payloads in directories named
    /// like this, wherever on disk they happen to sit.
    private static let transientComponents = ["TemporaryItems"]
    private static let transientComponentPrefixes = ["NSIRD_"]

    static func skipReason(for path: String, env: Environment = Environment()) -> ImportSkipReason? {
        let p = canonical(path)

        if p == "/" { return .root }
        if p == canonical(env.home) { return .home }
        if exactSkips.contains(p) { return .systemDirectory }

        var prefixes = transientPrefixes
        if let tmp = env.temporaryDirectory, !tmp.isEmpty { prefixes.append(canonical(tmp)) }
        for prefix in prefixes where p == prefix || p.hasPrefix(prefix + "/") {
            return .temporary
        }

        for component in p.split(separator: "/") {
            if transientComponents.contains(String(component)) { return .temporary }
            if transientComponentPrefixes.contains(where: { component.hasPrefix($0) }) { return .temporary }
        }

        return nil
    }

    /// Collapse macOS's `/private` aliasing — `/tmp` and `/var` are symlinks into
    /// `/private`, and Claude Code encodes whichever spelling the session's cwd
    /// resolved to — and drop a trailing slash, so both spellings compare equal.
    static func canonical(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        for alias in ["/var", "/tmp", "/etc"] where p == "/private" + alias || p.hasPrefix("/private" + alias + "/") {
            p.removeFirst("/private".count)
        }
        return p
    }
}
