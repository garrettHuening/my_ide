import Foundation

/// Everything that can move a subagent between states (spec §2 state table).
public enum SubagentEvent: Equatable, Sendable {
    case promptSubmitted            // UserPromptSubmit hook
    case toolUsed                   // PostToolUse hook
    case permissionPrompt           // Notification hook, permission_prompt
    case turnStopped                // Stop hook
    case markedComplete             // mark_complete tool
    case mergeRequested(needsCommit: Bool)
    case commitLanded               // clean tree + mark_complete while awaiting_commit
    case mergeCancelled(wasComplete: Bool) // commit timeout or merge_failed
    case mergeVerified              // mark_merged verified, branch tip unchanged
    case mergedWithNewerCommits     // mark_merged verified, but the branch moved on
    case archivedNothingToMerge     // Done button: no commits, clean tree
    case hostDied
    case relaunched                 // Resume / Reopen / recovery relaunch
    case userStopped
    case userDiscarded
    case spawnFailed
    case crashLoop
}

public struct IllegalTransition: Error, Equatable {
    public let from: SubagentPhase
    public let event: SubagentEvent
}

public enum SubagentStateMachine {
    /// States whose hook events are late arrivals from a process we no longer track.
    private static let archived: Set<SubagentState> = [.merged, .stopped, .failed, .discarded]

    public static func apply(_ event: SubagentEvent, to phase: SubagentPhase) throws -> SubagentPhase {
        let state = phase.state
        let illegal = IllegalTransition(from: phase, event: event)

        switch event {
        case .promptSubmitted:
            if archived.contains(state) || state == .merging { return phase }
            return SubagentPhase(.running)

        case .toolUsed:
            // mark_complete itself triggers PostToolUse; it must not undo `complete`.
            if archived.contains(state) || state == .merging || state == .complete { return phase }
            return SubagentPhase(.running)

        case .permissionPrompt:
            if archived.contains(state) || state == .merging { return phase }
            return SubagentPhase(.needsInput)

        case .turnStopped:
            if archived.contains(state) || state == .merging || state == .complete { return phase }
            return SubagentPhase(.idle)

        case .markedComplete:
            switch state {
            case .starting, .running, .idle, .needsInput, .complete:
                return SubagentPhase(.complete)
            case .merging where phase.substate == .awaitingCommit:
                return phase
            default:
                throw illegal
            }

        case .mergeRequested(let needsCommit):
            switch state {
            case .idle, .complete:
                return SubagentPhase(.merging, needsCommit ? .awaitingCommit : .awaitingMain)
            case .merging where phase.substate == .awaitingMain:
                return phase
            default:
                throw illegal
            }

        case .commitLanded:
            guard state == .merging, phase.substate == .awaitingCommit else { throw illegal }
            return SubagentPhase(.merging, .awaitingMain)

        case .mergeCancelled(let wasComplete):
            guard state == .merging else { throw illegal }
            return SubagentPhase(wasComplete ? .complete : .idle)

        case .mergeVerified:
            guard state == .merging, phase.substate == .awaitingMain else { throw illegal }
            return SubagentPhase(.merged)

        case .mergedWithNewerCommits:
            guard state == .merging, phase.substate == .awaitingMain else { throw illegal }
            return SubagentPhase(.idle)

        case .archivedNothingToMerge:
            guard state == .idle || state == .complete else { throw illegal }
            return SubagentPhase(.merged)

        case .hostDied:
            switch state {
            case .starting, .running, .needsInput:
                return SubagentPhase(.interrupted)
            default:
                return phase
            }

        case .relaunched:
            switch state {
            case .interrupted: return SubagentPhase(.running)
            case .stopped: return SubagentPhase(.idle)
            case .idle, .complete, .merging: return phase
            default: throw illegal
            }

        case .userStopped:
            switch state {
            case .starting, .running, .idle, .needsInput, .complete, .interrupted:
                return SubagentPhase(.stopped)
            case .stopped:
                return phase
            default:
                throw illegal
            }

        case .userDiscarded:
            switch state {
            case .merged, .discarded: throw illegal
            default: return SubagentPhase(.discarded)
            }

        case .spawnFailed:
            guard state == .starting else { throw illegal }
            return SubagentPhase(.failed)

        case .crashLoop:
            guard state == .interrupted else { throw illegal }
            return SubagentPhase(.failed)
        }
    }
}
