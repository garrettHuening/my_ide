import Foundation
@testable import CCHSubagents

/// Fixed reference time so tests never depend on the wall clock.
let epoch = Date(timeIntervalSince1970: 1_800_000_000)

func makeSubagent(
    id: Int64 = 1,
    category: SubagentCategory = .task,
    state: SubagentState = .idle,
    substate: MergeSubstate? = nil,
    groupID: Int64? = nil,
    index: Int? = nil
) -> Subagent {
    Subagent(
        id: id,
        sessionID: 1,
        category: category,
        title: "Subagent \(id)",
        state: state,
        mergeSubstate: substate,
        mergeGroupID: groupID,
        mergeIndex: index,
        createdAt: epoch,
        updatedAt: epoch
    )
}
