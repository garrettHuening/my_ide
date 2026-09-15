import Foundation

public enum MergeAction: Equatable, Sendable {
    case merge                  // start the merge flow (spec §5 steps 3–5)
    case archiveNothingToMerge  // Done button: no commits, clean tree (D9)
    case resend                 // Re-send Merge while awaiting main
}

public enum MergeBlock: Error, Equatable, Sendable {
    case busy                   // mid-turn or waiting on its own commit
    case waitsOn(index: Int)    // an earlier group member isn't merged yet (R11)
    case notMergeable           // interrupted, stopped, failed, merged, discarded
}

/// Whether the Merge button may act, enforced in agentd as well as the UI (spec §5 step 1).
public enum MergeGate {
    public static func evaluate(
        _ subagent: Subagent,
        groupMembers: [Subagent],
        hasCommits: Bool,
        isDirty: Bool
    ) -> Result<MergeAction, MergeBlock> {
        switch subagent.state {
        case .merging:
            return subagent.mergeSubstate == .awaitingMain ? .success(.resend) : .failure(.busy)
        case .starting, .running, .needsInput:
            return .failure(.busy)
        case .interrupted, .stopped, .failed, .merged, .discarded:
            return .failure(.notMergeable)
        case .idle, .complete:
            break
        }

        if let groupID = subagent.mergeGroupID, let index = subagent.mergeIndex {
            let blocker = groupMembers
                .filter { $0.id != subagent.id && $0.mergeGroupID == groupID }
                .filter { $0.state != .merged && $0.state != .discarded }
                .compactMap(\.mergeIndex)
                .filter { $0 < index }
                .min()
            if let blocker { return .failure(.waitsOn(index: blocker)) }
        }

        return (!hasCommits && !isDirty) ? .success(.archiveNothingToMerge) : .success(.merge)
    }
}
