import XCTest
@testable import CCHSubagents

final class HookPolicyTests: XCTestCase {
    func testStopBlocksWhenNoReportThisTurn() {
        var s = makeSubagent(state: .running)
        s.turnsStarted = 2
        s.lastReportTurn = 1
        XCTAssertEqual(HookPolicy.onStop(s, stopHookActive: false), .blockStop(reason: HookPolicy.stopReason))
    }

    func testStopBlocksBrandNewSubagent() {
        let s = makeSubagent(state: .starting)  // turnsStarted 0, lastReportTurn -1
        XCTAssertEqual(HookPolicy.onStop(s, stopHookActive: false), .blockStop(reason: HookPolicy.stopReason))
    }

    func testStopAllowedWhenReportedThisTurn() {
        var s = makeSubagent(state: .running)
        s.turnsStarted = 2
        s.lastReportTurn = 2
        XCTAssertEqual(HookPolicy.onStop(s, stopHookActive: false), .none)
    }

    func testStopNeverBlocksTwiceOrAfterCompletion() {
        var s = makeSubagent(state: .running)
        s.turnsStarted = 2
        s.lastReportTurn = 1
        XCTAssertEqual(HookPolicy.onStop(s, stopHookActive: true), .none)
        s.completedAt = epoch
        XCTAssertEqual(HookPolicy.onStop(s, stopHookActive: false), .none)
    }

    func testPostToolUseRemindsAfterTenMinutesSinceCreation() {
        var s = makeSubagent(state: .running)
        s.createdAt = epoch.addingTimeInterval(-601)
        XCTAssertEqual(HookPolicy.onPostToolUse(s, now: epoch),
                       .addContext(event: "PostToolUse", text: HookPolicy.reminderText))
    }

    func testPostToolUseUsesLastReportTime() {
        var s = makeSubagent(state: .running)
        s.createdAt = epoch.addingTimeInterval(-7200)
        s.lastReportAt = epoch.addingTimeInterval(-30)
        XCTAssertEqual(HookPolicy.onPostToolUse(s, now: epoch), .none)
        s.lastReportAt = epoch.addingTimeInterval(-700)
        XCTAssertEqual(HookPolicy.onPostToolUse(s, now: epoch),
                       .addContext(event: "PostToolUse", text: HookPolicy.reminderText))
    }

    func testPostToolUseSilentAfterCompletion() {
        var s = makeSubagent(state: .complete)
        s.createdAt = epoch.addingTimeInterval(-7200)
        s.completedAt = epoch
        XCTAssertEqual(HookPolicy.onPostToolUse(s, now: epoch), .none)
    }

    func testStdoutShapes() throws {
        XCTAssertTrue(HookPolicy.stdout(for: .none).isEmpty)

        let block = try JSONSerialization.jsonObject(
            with: HookPolicy.stdout(for: .blockStop(reason: "why"))) as? [String: Any]
        XCTAssertEqual(block?["decision"] as? String, "block")
        XCTAssertEqual(block?["reason"] as? String, "why")

        let context = try JSONSerialization.jsonObject(
            with: HookPolicy.stdout(for: .addContext(event: "PostToolUse", text: "hi"))) as? [String: Any]
        let specific = context?["hookSpecificOutput"] as? [String: Any]
        XCTAssertEqual(specific?["hookEventName"] as? String, "PostToolUse")
        XCTAssertEqual(specific?["additionalContext"] as? String, "hi")
    }
}
