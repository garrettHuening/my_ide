import Foundation

public struct ResolvedProject: Equatable, Sendable {
    public let key: String
    public let name: String
    public let root: String
    public let branch: String?
}

/// Identifies which project a working directory belongs to. Every checkout and worktree of the
/// same repository shares one key, so their memories are shared (spec: scope = this repo).
public enum ProjectKey {
    /// `git@github.com:me/app.git`, `https://me@github.com/me/app`, `ssh://git@github.com:22/me/app.git`
    /// all become `github.com/me/app`.
    public static func normalizeRemote(_ remote: String) -> String? {
        var s = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }

        if let schemeRange = s.range(of: "://") {
            s = String(s[schemeRange.upperBound...])
            if let at = s.firstIndex(of: "@"), at < (s.firstIndex(of: "/") ?? s.endIndex) {
                s = String(s[s.index(after: at)...])
            }
            // Drop a :port on the host.
            if let slash = s.firstIndex(of: "/") {
                let host = s[..<slash]
                if let colon = host.firstIndex(of: ":") {
                    s = String(host[..<colon]) + String(s[slash...])
                }
            }
        } else if let at = s.firstIndex(of: "@"), let colon = s.firstIndex(of: ":"), at < colon {
            // scp-like: user@host:path
            s = String(s[s.index(after: at)..<colon]) + "/" + String(s[s.index(after: colon)...])
        } else if s.hasPrefix("/") {
            return nil // local path remote: not a stable shared identity
        }
        let parts = s.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return parts.joined(separator: "/").lowercased()
    }

    /// Whether a key identifies a repository by its shared remote rather than by a path on this
    /// machine. Remote keys are `host/owner/name`; the path fallback is always absolute.
    public static func isRemoteKey(_ key: String) -> Bool {
        !key.hasPrefix("/")
    }

    /// Resolves a directory to its project. Uses git when available; a non-git folder is its
    /// own project keyed by its standardized path.
    public static func resolve(directory: String, git: GitRunner = GitRunner()) -> ResolvedProject {
        let dir = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath().path
        guard let top = git.output(["rev-parse", "--show-toplevel"], in: dir) else {
            return ResolvedProject(key: dir, name: (dir as NSString).lastPathComponent, root: dir, branch: nil)
        }
        let branch = git.output(["symbolic-ref", "--short", "-q", "HEAD"], in: dir)
        // The main checkout (not the worktree) names the project.
        var mainRoot = top
        if let common = git.output(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: dir) {
            let parent = (common as NSString).deletingLastPathComponent
            if (common as NSString).lastPathComponent == ".git" { mainRoot = parent }
        }
        let name = (mainRoot as NSString).lastPathComponent
        if let remote = git.output(["remote", "get-url", "origin"], in: dir), let key = normalizeRemote(remote) {
            return ResolvedProject(key: key, name: name, root: mainRoot, branch: branch)
        }
        return ResolvedProject(key: mainRoot, name: name, root: mainRoot, branch: branch)
    }
}

public struct GitRunner: Sendable {
    public var executable: String

    public init(executable: String = "/usr/bin/git") {
        self.executable = executable
    }

    /// Trimmed stdout, or nil on failure / empty output.
    public func output(_ args: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-C", directory] + args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
}
