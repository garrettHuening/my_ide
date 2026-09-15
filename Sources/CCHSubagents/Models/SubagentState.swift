import Foundation

/// Lifecycle state of a subagent (spec §2). Raw values are stored in agents.db.
public enum SubagentState: String, CaseIterable, Codable, Sendable {
    case starting
    case running
    case idle
    case needsInput = "needs_input"
    case complete
    case merging
    case merged
    case interrupted
    case stopped
    case failed
    case discarded
}

/// Which step of the merge flow a `.merging` subagent is in.
public enum MergeSubstate: String, Codable, Sendable {
    case awaitingCommit = "awaiting_commit"
    case awaitingMain = "awaiting_main"
}

/// A state plus its merge substate, the unit the state machine works on.
public struct SubagentPhase: Hashable, Sendable, CustomStringConvertible {
    public var state: SubagentState
    public var substate: MergeSubstate?

    public init(_ state: SubagentState, _ substate: MergeSubstate? = nil) {
        self.state = state
        self.substate = substate
    }

    public var description: String {
        substate.map { "\(state.rawValue)/\($0.rawValue)" } ?? state.rawValue
    }
}
