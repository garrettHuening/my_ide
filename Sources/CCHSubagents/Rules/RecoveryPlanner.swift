import Foundation

/// What to type into a relaunched subagent.
public enum RecoveryNudge: Equatable, Sendable {
    case none            // resume silently
    case continueWork    // "You were interrupted… continue from Next"
    case commitRequest   // resend the merge commit request
}

public enum RecoveryAction: Equatable, Sendable {
    case nothing
    case reattach
    case relaunch(RecoveryNudge)
    case awaitManualResume
    case fail(reason: String)
}

public struct RecoveryPolicy: Equatable, Sendable {
    public var autoResume: Bool
    public var maxResumes: Int
    public var window: TimeInterval

    public init(autoResume: Bool = true, maxResumes: Int = 3, window: TimeInterval = 30 * 60) {
        self.autoResume = autoResume
        self.maxResumes = maxResumes
        self.window = window
    }
}

/// Per-subagent decision cch-agentd makes on startup (spec §2 Recovery table, R13/R14).
public enum RecoveryPlanner {
    public static let crashLoopReason = "crash loop"

    public static func plan(
        for subagent: Subagent,
        hostAlive: Bool,
        now: Date,
        policy: RecoveryPolicy = RecoveryPolicy()
    ) -> RecoveryAction {
        switch subagent.state {
        case .merged, .stopped, .failed, .discarded:
            return .nothing

        case .complete:
            return hostAlive ? .reattach : .nothing

        case .merging:
            if hostAlive { return .reattach }
            return subagent.mergeSubstate == .awaitingCommit ? .relaunch(.commitRequest) : .nothing

        case .idle:
            return hostAlive ? .reattach : .relaunch(.none)

        case .starting, .running, .needsInput, .interrupted:
            if hostAlive { return .reattach }
            if isCrashLooping(subagent, now: now, policy: policy) { return .fail(reason: crashLoopReason) }
            return policy.autoResume ? .relaunch(.continueWork) : .awaitManualResume
        }
    }

    static func isCrashLooping(_ subagent: Subagent, now: Date, policy: RecoveryPolicy) -> Bool {
        guard let last = subagent.lastResumeAt, now.timeIntervalSince(last) < policy.window else { return false }
        return subagent.resumeCount >= policy.maxResumes
    }
}
