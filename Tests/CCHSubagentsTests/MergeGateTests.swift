import XCTest
@testable import CCHSubagents

final class MergeGateTests: XCTestCase {
    private func gate(_ s: Subagent, members: [Subagent] = [], commits: Bool = true, dirty: Bool = false)
        -> Result<MergeAction, MergeBlock> {
        MergeGate.evaluate(s, groupMembers: members, hasCommits: commits, isDirty: dirty)
    }

    func testUngroupedIdleWithCommitsMerges() {
        XCTAssertEqual(gate(makeSubagent(state: .idle)), .success(.merge))
    }

    func testDirtyTreeWithoutCommitsStillMerges() {
        XCTAssertEqual(gate(makeSubagent(state: .idle), commits: false, dirty: true), .success(.merge))
    }

    func testNothingToMergeArchives() {
        XCTAssertEqual(gate(makeSubagent(state: .complete), commits: false, dirty: false),
                       .success(.archiveNothingToMerge))
    }

    func testBusyStates() {
        for state in [SubagentState.starting, .running, .needsInput] {
            XCTAssertEqual(gate(makeSubagent(state: state)), .failure(.busy))
        }
        XCTAssertEqual(gate(makeSubagent(state: .merging, substate: .awaitingCommit)), .failure(.busy))
    }

    func testAwaitingMainResends() {
        XCTAssertEqual(gate(makeSubagent(state: .merging, substate: .awaitingMain)), .success(.resend))
    }

    func testNotMergeableStates() {
        for state in [SubagentState.interrupted, .stopped, .failed, .merged, .discarded] {
            XCTAssertEqual(gate(makeSubagent(state: state)), .failure(.notMergeable))
        }
    }

    func testGroupWaitsOnLowestUnmergedPredecessor() {
        let first = makeSubagent(id: 1, state: .idle, groupID: 9, index: 1)
        let second = makeSubagent(id: 2, state: .complete, groupID: 9, index: 2)
        XCTAssertEqual(gate(second, members: [first, second]), .failure(.waitsOn(index: 1)))
    }

    func testGroupPredecessorsMergedOrDiscardedUnblock() {
        let first = makeSubagent(id: 1, state: .merged, groupID: 9, index: 1)
        let second = makeSubagent(id: 2, state: .discarded, groupID: 9, index: 2)
        let third = makeSubagent(id: 3, state: .idle, groupID: 9, index: 3)
        XCTAssertEqual(gate(third, members: [first, second, third]), .success(.merge))
    }

    func testGroupBlockedBySecondWhenFirstMerged() {
        let first = makeSubagent(id: 1, state: .merged, groupID: 9, index: 1)
        let second = makeSubagent(id: 2, state: .running, groupID: 9, index: 2)
        let third = makeSubagent(id: 3, state: .idle, groupID: 9, index: 3)
        XCTAssertEqual(gate(third, members: [first, second, third]), .failure(.waitsOn(index: 2)))
    }

    func testMembersOfOtherGroupsAreIgnored() {
        let other = makeSubagent(id: 1, state: .idle, groupID: 4, index: 1)
        let mine = makeSubagent(id: 2, state: .idle, groupID: 9, index: 2)
        XCTAssertEqual(gate(mine, members: [other, mine]), .success(.merge))
    }
}
