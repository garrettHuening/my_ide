import Foundation

/// Every message the Hub types into or appends for Claude (spec §2, §3, §5).
public enum SubagentPrompts {
    public static let mainToolPrefix = "mcp__plugin_cch-main_cch__"
    public static let subagentToolPrefix = "mcp__plugin_cch-sub_cch__"

    public static func guidance(for category: SubagentCategory) -> String {
        switch category {
        case .task: return "This is a TASK: a scoped change. Follow the brief exactly and keep the change minimal."
        case .bug: return "This is a BUG FIX: reproduce the problem, find the root cause, fix it, and add a regression test when the project has tests. If a core-memory bug (BUG-n) is named in the brief, call bug_fix and bug_learning on it before finishing."
        case .feature: return "This is a FEATURE: implement it against the acceptance criteria in the brief, with tests where the project has them."
        case .helper: return "This is a HELPER: research, analysis or support work. You may write notes or make small edits; commit anything worth keeping. It is fine to finish with nothing to commit."
        }
    }

    public static func systemRules(category: SubagentCategory, branch: String) -> String {
        let p = subagentToolPrefix
        return """
        You are a Claude Code Hub subagent working in an isolated git worktree on branch \(branch). The main session started you and will merge your branch when you're done.
        \(guidance(for: category))
        Rules:
        - Commit in small logical steps on this branch. Never push, never switch branches, never touch the main checkout.
        - Call \(p)report_status (summary, done, next) after each meaningful step and before ending any turn, so work can resume after a crash.
        - When the brief is fully done and everything is committed, call \(p)mark_complete with a short summary.
        - If you are blocked or need a decision, say so clearly and stop; the user or the main session will message you.
        """
    }

    public static func continueNudge(report: StatusReport?, commits: String, uncommitted: [String]) -> String {
        var text = "You were interrupted by a crash or restart."
        if let report {
            text += " Your last status report: \(report.summary)."
            if !report.done.isEmpty { text += " Done: \(report.done.joined(separator: "; "))." }
            if !report.next.isEmpty { text += " Next: \(report.next.joined(separator: "; "))." }
        } else {
            text += " You had not reported status yet."
        }
        text += " Commits on your branch: \(commits.isEmpty ? "none" : commits.replacingOccurrences(of: "\n", with: "; "))."
        text += " Uncommitted files: \(uncommitted.isEmpty ? "none" : uncommitted.joined(separator: ", "))."
        text += " Your uncommitted changes in the worktree are intact. Continue from where you left off."
        return text
    }

    public static let commitRequest =
        "The main session is about to merge your branch. Commit all of your remaining work now with a descriptive message, then call \(subagentToolPrefix)mark_complete with a short summary."

    public static func mergeRequest(subagent s: Subagent, summary: String, commits: String, diffStat: String) -> String {
        let p = mainToolPrefix
        return """
        [Claude Code Hub merge request · subagent #\(s.id)] Merge branch `\(s.branch)` (subagent "\(s.title)", based on `\(s.baseCommit.prefix(7))`) into your current branch.
        Subagent summary: \(summary.isEmpty ? "(none reported)" : summary)
        Commits:
        \(commits.isEmpty ? "(none)" : commits)
        Files:
        \(diffStat.isEmpty ? "(none)" : diffStat)
        Steps: (1) make sure your working tree is clean — commit your own work first, or ask me if unsure; (2) `git merge --no-ff \(s.branch)`; (3) resolve any conflicts preserving both sides' intent; (4) run the project's build and tests; (5) call \(p)mark_merged(id: \(s.id), merge_commit: <sha>). If you can't finish, call \(p)merge_failed(id: \(s.id), reason: …).
        """
    }
}
