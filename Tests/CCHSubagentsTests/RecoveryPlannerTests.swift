import XCTest
@testable import CCHSubagents

final class RecoveryPlannerTests: XCTestCase {
    private func plan(_ s: Subagent, alive: Bool, auto: Bool = true) -> RecoveryAction {
        RecoveryPlanner.plan(for: s, hostAlive: alive, now: epoch, policy: RecoveryPolicy(autoResume: auto))
    }

    func testLiveHostsReattach() {
        for state in [SubagentState.starting, .running, .needsInput, .idle, .interrupted, .complete] {
            XCTAssertEqual(plan(makeSubagent(state: state), alive: true), .reattach, "\(state)")
        }
        XCTAssertEqual(plan(makeSubagent(state: .merging, substate: .awaitingMain), alive: true), .reattach)
    }

    func testDeadWorkingSubagentsResumeWithNudge() {
        for state in [SubagentState.starting, .running, .needsInput, .interrupted] {
            XCTAssertEqual(plan(makeSubagent(state: state), alive: false), .relaunch(.continueWork), "\(state)")
        }
    }

    func testManualResumePolicyWaitsForClick() {
        XCTAssertEqual(plan(makeSubagent(state: .running), alive: false, auto: false), .awaitManualResume)
        XCTAssertEqual(plan(makeSubagent(state: .interrupted), alive: false, auto: false), .awaitManualResume)
    }

    func testDeadIdleSubagentRelaunchesSilentlyEvenWhenManual() {
        XCTAssertEqual(plan(makeSubagent(state: .idle), alive: false), .relaunch(.none))
        XCTAssertEqual(plan(makeSubagent(state: .idle), alive: false, auto: false), .relaunch(.none))
    }

    func testMergingSubstates() {
        XCTAssertEqual(plan(makeSubagent(state: .merging, substate: .awaitingCommit), alive: false),
                       .relaunch(.commitRequest))
        XCTAssertEqual(plan(makeSubagent(state: .merging, substate: .awaitingMain), alive: false), .nothing)
    }

    func testFinishedSubagentsNeverRestart() {
        for state in [SubagentState.complete, .merged, .stopped, .failed, .discarded] {
            XCTAssertEqual(plan(makeSubagent(state: state), alive: false), .nothing, "\(state)")
        }
    }

    func testStrayHostForArchivedSubagentIsLeftAlone() {
        for state in [SubagentState.merged, .stopped, .failed, .discarded] {
            XCTAssertEqual(plan(makeSubagent(state: state), alive: true), .nothing, "\(state)")
        }
    }

    func testCrashLoopFails() {
        var s = makeSubagent(state: .running)
        s.resumeCount = 3
        s.lastResumeAt = epoch.addingTimeInterval(-60)
        XCTAssertEqual(plan(s, alive: false), .fail(reason: "crash loop"))
    }

    func testOldResumesDoNotCount() {
        var s = makeSubagent(state: .running)
        s.resumeCount = 3
        s.lastResumeAt = epoch.addingTimeInterval(-3600)
        XCTAssertEqual(plan(s, alive: false), .relaunch(.continueWork))
    }

    func testBelowLimitStillResumes() {
        var s = makeSubagent(state: .interrupted)
        s.resumeCount = 2
        s.lastResumeAt = epoch.addingTimeInterval(-60)
        XCTAssertEqual(plan(s, alive: false), .relaunch(.continueWork))
    }
}
