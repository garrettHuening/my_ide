import CryptoKit
import Foundation

/// Branch, worktree and working-directory names for a subagent (spec §3 spawn steps 4–7).
public enum SubagentNaming {
    /// Lowercase ASCII alphanumerics joined by single dashes, at most `maxLength` characters.
    public static func slug(_ title: String, maxLength: Int = 32) -> String {
        var out = ""
        var lastWasDash = false
        for scalar in title.lowercased().unicodeScalars {
            if scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash && !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > maxLength {
            out = String(out.prefix(maxLength))
            while out.hasSuffix("-") { out.removeLast() }
        }
        return out.isEmpty ? "subagent" : out
    }

    public static func branch(category: SubagentCategory, id: Int64, title: String) -> String {
        "cch/\(category.rawValue)/\(id)-\(slug(title))"
    }

    /// `<worktreesRoot>/<repo basename>-<sha1(repoRoot) prefix>/<id>-<slug>`. The hash keeps two
    /// repos with the same folder name apart.
    public static func worktreePath(worktreesRoot: String, repoRoot: String, id: Int64, title: String) -> String {
        let repoName = (repoRoot as NSString).lastPathComponent
        let digest = Insecure.SHA1.hash(data: Data(repoRoot.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        return "\(worktreesRoot)/\(repoName)-\(hash)/\(id)-\(slug(title))"
    }

    /// If the session was opened in a subfolder of the repo, the subagent starts in the same
    /// subfolder of its worktree.
    public static func workingDirectory(worktreePath: String, sessionDir: String, repoRoot: String) -> String {
        let root = repoRoot.hasSuffix("/") ? String(repoRoot.dropLast()) : repoRoot
        guard sessionDir.hasPrefix(root + "/") else { return worktreePath }
        let relative = sessionDir.dropFirst(root.count + 1)
        return relative.isEmpty ? worktreePath : "\(worktreePath)/\(relative)"
    }
}
