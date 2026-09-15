import XCTest
@testable import CCHSubagents

final class SubagentStateMachineTests: XCTestCase {
    private func p(_ state: SubagentState, _ substate: MergeSubstate? = nil) -> SubagentPhase {
        SubagentPhase(state, substate)
    }

    private func expect(_ from: SubagentPhase, _ event: SubagentEvent, _ to: SubagentPhase,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(try SubagentStateMachine.apply(event, to: from), to, file: file, line: line)
    }

    private func expectIllegal(_ from: SubagentPhase, _ event: SubagentEvent,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try SubagentStateMachine.apply(event, to: from), file: file, line: line) { error in
            XCTAssertEqual(error as? IllegalTransition, IllegalTransition(from: from, event: event),
                           file: file, line: line)
        }
    }

    func testHooksDriveRunningIdleAndNeedsInput() {
        expect(p(.starting), .promptSubmitted, p(.running))
        expect(p(.running), .permissionPrompt, p(.needsInput))
        expect(p(.needsInput), .toolUsed, p(.running))
        expect(p(.running), .turnStopped, p(.idle))
        expect(p(.idle), .promptSubmitted, p(.running))
        expect(p(.interrupted), .promptSubmitted, p(.running))
        expect(p(.starting), .turnStopped, p(.idle))
    }

    func testCompleteSurvivesTrailingHooksButReopensOnNewPrompt() {
        expect(p(.complete), .toolUsed, p(.complete))
        expect(p(.complete), .turnStopped, p(.complete))
        expect(p(.complete), .promptSubmitted, p(.running))
    }

    func testHooksAreIgnoredWhileMergingAndAfterArchive() {
        let hookEvents: [SubagentEvent] = [.promptSubmitted, .toolUsed, .permissionPrompt, .turnStopped]
        for state in [SubagentState.merged, .stopped, .failed, .discarded] {
            for event in hookEvents {
                expect(p(state), event, p(state))
            }
        }
        for event in hookEvents {
            expect(p(.merging, .awaitingCommit), event, p(.merging, .awaitingCommit))
            expect(p(.merging, .awaitingMain), event, p(.merging, .awaitingMain))
        }
    }

    func testMarkComplete() {
        expect(p(.running), .markedComplete, p(.complete))
        expect(p(.idle), .markedComplete, p(.complete))
        expect(p(.complete), .markedComplete, p(.complete))
        expect(p(.merging, .awaitingCommit), .markedComplete, p(.merging, .awaitingCommit))
        expectIllegal(p(.merging, .awaitingMain), .markedComplete)
        expectIllegal(p(.merged), .markedComplete)
        expectIllegal(p(.stopped), .markedComplete)
    }

    func testMergeRequest() {
        expect(p(.idle), .mergeRequested(needsCommit: true), p(.merging, .awaitingCommit))
        expect(p(.complete), .mergeRequested(needsCommit: false), p(.merging, .awaitingMain))
        expect(p(.merging, .awaitingMain), .mergeRequested(needsCommit: false), p(.merging, .awaitingMain))
        expectIllegal(p(.running), .mergeRequested(needsCommit: false))
        expectIllegal(p(.merging, .awaitingCommit), .mergeRequested(needsCommit: true))
        expectIllegal(p(.merged), .mergeRequested(needsCommit: false))
    }

    func testCommitLandedAndCancel() {
        expect(p(.merging, .awaitingCommit), .commitLanded, p(.merging, .awaitingMain))
        expectIllegal(p(.merging, .awaitingMain), .commitLanded)
        expect(p(.merging, .awaitingCommit), .mergeCancelled(wasComplete: false), p(.idle))
        expect(p(.merging, .awaitingMain), .mergeCancelled(wasComplete: true), p(.complete))
        expectIllegal(p(.idle), .mergeCancelled(wasComplete: false))
    }

    func testMergeVerification() {
        expect(p(.merging, .awaitingMain), .mergeVerified, p(.merged))
        expect(p(.merging, .awaitingMain), .mergedWithNewerCommits, p(.idle))
        expectIllegal(p(.merging, .awaitingCommit), .mergeVerified)
        expectIllegal(p(.merging, .awaitingCommit), .mergedWithNewerCommits)
        expect(p(.idle), .archivedNothingToMerge, p(.merged))
        expect(p(.complete), .archivedNothingToMerge, p(.merged))
        expectIllegal(p(.running), .archivedNothingToMerge)
    }

    func testHostDeath() {
        expect(p(.starting), .hostDied, p(.interrupted))
        expect(p(.running), .hostDied, p(.interrupted))
        expect(p(.needsInput), .hostDied, p(.interrupted))
        expect(p(.idle), .hostDied, p(.idle))
        expect(p(.complete), .hostDied, p(.complete))
        expect(p(.merging, .awaitingCommit), .hostDied, p(.merging, .awaitingCommit))
        expect(p(.interrupted), .hostDied, p(.interrupted))
    }

    func testRelaunch() {
        expect(p(.interrupted), .relaunched, p(.running))
        expect(p(.stopped), .relaunched, p(.idle))
        expect(p(.idle), .relaunched, p(.idle))
        expect(p(.complete), .relaunched, p(.complete))
        expect(p(.merging, .awaitingCommit), .relaunched, p(.merging, .awaitingCommit))
        expectIllegal(p(.merged), .relaunched)
        expectIllegal(p(.discarded), .relaunched)
        expectIllegal(p(.failed), .relaunched)
    }

    func testUserStopAndDiscard() {
        for state in [SubagentState.starting, .running, .idle, .needsInput, .complete, .interrupted] {
            expect(p(state), .userStopped, p(.stopped))
        }
        expect(p(.stopped), .userStopped, p(.stopped))
        expectIllegal(p(.merging, .awaitingMain), .userStopped)
        expectIllegal(p(.merged), .userStopped)

        expect(p(.failed), .userDiscarded, p(.discarded))
        expect(p(.merging, .awaitingCommit), .userDiscarded, p(.discarded))
        expectIllegal(p(.merged), .userDiscarded)
        expectIllegal(p(.discarded), .userDiscarded)
    }

    func testFailures() {
        expect(p(.starting), .spawnFailed, p(.failed))
        expectIllegal(p(.running), .spawnFailed)
        expect(p(.interrupted), .crashLoop, p(.failed))
        expectIllegal(p(.idle), .crashLoop)
    }
}
