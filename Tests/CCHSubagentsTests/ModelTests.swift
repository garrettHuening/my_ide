import XCTest
@testable import CCHSubagents

final class ModelTests: XCTestCase {
    func testCommandNamesShipBugAsBugfix() {
        XCTAssertEqual(SubagentCategory.allCases.map(\.commandName), ["task", "bugfix", "feature", "helper"])
    }

    func testInitFromCommandName() {
        XCTAssertEqual(SubagentCategory(commandName: "bugfix"), .bug)
        XCTAssertEqual(SubagentCategory(commandName: "helper"), .helper)
        XCTAssertNil(SubagentCategory(commandName: "bug"))
    }

    func testDisplayNames() {
        XCTAssertEqual(SubagentCategory.allCases.map(\.displayName), ["Task", "Bug", "Feature", "Helper"])
    }

    func testRawValuesMatchSpecColumns() {
        XCTAssertEqual(SubagentCategory.allCases.map(\.rawValue), ["task", "bug", "feature", "helper"])
        XCTAssertEqual(SubagentState.needsInput.rawValue, "needs_input")
        XCTAssertEqual(SubagentState.allCases.count, 11)
        XCTAssertEqual(MergeSubstate.awaitingCommit.rawValue, "awaiting_commit")
        XCTAssertEqual(MergeSubstate.awaitingMain.rawValue, "awaiting_main")
    }

    func testPhaseReadsAndWritesStateAndSubstate() {
        var s = makeSubagent(state: .idle)
        XCTAssertEqual(s.phase, SubagentPhase(.idle))
        s.phase = SubagentPhase(.merging, .awaitingMain)
        XCTAssertEqual(s.state, .merging)
        XCTAssertEqual(s.mergeSubstate, .awaitingMain)
    }
}
