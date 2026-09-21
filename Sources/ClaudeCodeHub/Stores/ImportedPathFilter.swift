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

    /// Today: no canonicalisation at all.
    static func canonical(_ path: String) -> String { path }

    static func skipReason(for path: String, env: Environment = Environment()) -> ImportSkipReason? {
        let skipPaths: Set<String> = [
            env.home,
            "/",
            "/tmp",
            "/var"
        ]
        return skipPaths.contains(path) ? .systemDirectory : nil
    }
}
