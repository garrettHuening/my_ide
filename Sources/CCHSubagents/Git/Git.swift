import Foundation

public struct GitResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public var ok: Bool { status == 0 }
}

/// Git operations for worktrees and merges (spec §3, §5).
public struct Git: Sendable {
    public var executable = "/usr/bin/git"

    public init() {}

    @discardableResult
    public func run(_ args: [String], in directory: String) -> GitResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-C", directory] + args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return GitResult(status: -1, stdout: "", stderr: "\(error)")
        }
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return GitResult(status: process.terminationStatus,
                         stdout: String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                         stderr: String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    public func value(_ args: [String], in directory: String) -> String? {
        let result = run(args, in: directory)
        return result.ok && !result.stdout.isEmpty ? result.stdout : nil
    }

    public func topLevel(_ directory: String) -> String? { value(["rev-parse", "--show-toplevel"], in: directory) }
    public func head(_ directory: String) -> String? { value(["rev-parse", "HEAD"], in: directory) }
    public func branch(_ directory: String) -> String? { value(["symbolic-ref", "--short", "-q", "HEAD"], in: directory) }
    public func tip(of branch: String, in directory: String) -> String? { value(["rev-parse", branch], in: directory) }

    public func dirtyFiles(_ directory: String) -> [String] {
        run(["status", "--porcelain"], in: directory).stdout.split(separator: "\n").map { String($0.dropFirst(3)) }
    }

    public func commitCount(from base: String, to tip: String, in directory: String) -> Int {
        Int(value(["rev-list", "--count", "\(base)..\(tip)"], in: directory) ?? "") ?? 0
    }

    public func changedFiles(from base: String, in directory: String) -> [String] {
        let committed = run(["diff", "--name-only", "\(base)..HEAD"], in: directory).stdout.split(separator: "\n").map(String.init)
        return Array(Set(committed + dirtyFiles(directory))).sorted()
    }

    public func log(from base: String, to tip: String, in directory: String) -> String {
        run(["log", "--oneline", "\(base)..\(tip)"], in: directory).stdout
    }

    public func diffStat(from base: String, to tip: String, in directory: String) -> String {
        run(["diff", "--stat", "\(base)..\(tip)"], in: directory).stdout
    }

    public func isAncestor(_ commit: String, of target: String, in directory: String) -> Bool {
        run(["merge-base", "--is-ancestor", commit, target], in: directory).ok
    }

    @discardableResult
    public func addWorktree(repoRoot: String, path: String, branch: String, base: String) -> GitResult {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        return run(["worktree", "add", "-b", branch, path, base], in: repoRoot)
    }

    @discardableResult
    public func removeWorktree(repoRoot: String, path: String, force: Bool) -> GitResult {
        run(["worktree", "remove"] + (force ? ["--force"] : []) + [path], in: repoRoot)
    }

    @discardableResult
    public func deleteBranch(repoRoot: String, branch: String, force: Bool) -> GitResult {
        run(["branch", force ? "-D" : "-d", branch], in: repoRoot)
    }
}

/// Reads Claude Code's per-folder trust from `~/.claude.json`.
public enum ClaudeTrust {
    public static func isTrusted(_ path: String, configPath: String = NSHomeDirectory() + "/.claude.json") -> Bool {
        guard let data = FileManager.default.contents(atPath: configPath),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = config["projects"] as? [String: Any] else { return false }
        var candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        while true {
            if let entry = projects[candidate] as? [String: Any], entry["hasTrustDialogAccepted"] as? Bool == true { return true }
            let parent = (candidate as NSString).deletingLastPathComponent
            if parent == candidate || parent.isEmpty { return false }
            candidate = parent
        }
    }

    /// True when terminal output shows Claude's folder-trust prompt.
    public static func isTrustPrompt(_ screenText: String) -> Bool {
        plainLetters(screenText).contains("yesitrustthisfolder")
    }

    private static let escapeSequences = try! NSRegularExpression(
        pattern: "\u{1b}\\[[0-9;?<>=]*[ -/]*[@-~]|\u{1b}\\][^\u{07}\u{1b}]*(\u{07}|\u{1b}\\\\)|\u{1b}[()][0-9A-Za-z]|\u{1b}[=>78]")

    /// Lowercase letters only, with terminal escape sequences removed first (their final bytes are letters).
    public static func plainLetters(_ text: String) -> String {
        let stripped = escapeSequences.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        return stripped.lowercased().filter(\.isLetter)
    }
}
