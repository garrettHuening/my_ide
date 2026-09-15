import Foundation

public enum HookReply: Equatable, Sendable {
    case none
    case blockStop(reason: String)
    case addContext(event: String, text: String)
}

/// Decisions for Claude Code hook events coming from subagents (spec §2 "Status reporting").
public enum HookPolicy {
    public static let stopReason = "Call report_status (summary, done, next) before stopping."
    public static let reminderInterval: TimeInterval = 10 * 60
    public static let reminderText =
        "It has been over 10 minutes since your last report_status. Call it now, then continue."

    /// Block the end of a turn once if the subagent hasn't reported during it.
    public static func onStop(_ subagent: Subagent, stopHookActive: Bool) -> HookReply {
        if stopHookActive || subagent.completedAt != nil { return .none }
        return subagent.lastReportTurn < subagent.turnsStarted ? .blockStop(reason: stopReason) : .none
    }

    /// Nudge long-running turns that haven't reported for `reminderInterval`.
    public static func onPostToolUse(_ subagent: Subagent, now: Date) -> HookReply {
        if subagent.completedAt != nil { return .none }
        let since = subagent.lastReportAt ?? subagent.createdAt
        guard now.timeIntervalSince(since) > reminderInterval else { return .none }
        return .addContext(event: "PostToolUse", text: reminderText)
    }

    /// JSON printed by `cch-mcp hook <event>`. Empty data means print nothing.
    public static func stdout(for reply: HookReply) -> Data {
        let object: [String: Any]
        switch reply {
        case .none:
            return Data()
        case .blockStop(let reason):
            object = ["decision": "block", "reason": reason]
        case .addContext(let event, let text):
            object = ["hookSpecificOutput": ["hookEventName": event, "additionalContext": text]]
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}
