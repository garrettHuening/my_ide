import XCTest
@testable import CCHSubagents

final class SubagentModelTests: XCTestCase {
    func testValidValues() {
        for value in ["fable", "opus", "sonnet", "haiku", "sonnet[1m]",
                      "claude-haiku-4-5-20251001", "claude-opus-5", "claude-opus-5[1m]", "claude-fable-5-1"] {
            XCTAssertTrue(SubagentModel.isValid(value), value)
        }
    }

    func testInvalidValues() {
        for value in ["", "Opus", "gpt-5", "claude-", "opus; rm -rf ~", "claude-opus 5", "haiku[2m]"] {
            XCTAssertFalse(SubagentModel.isValid(value), value)
        }
    }

    func testResolveOverrideWinsAndBlanksMeanUnset() {
        XCTAssertEqual(SubagentModel.resolve(override: "haiku", categoryDefault: "opus"), "haiku")
        XCTAssertEqual(SubagentModel.resolve(override: "  ", categoryDefault: "opus"), "opus")
        XCTAssertEqual(SubagentModel.resolve(override: nil, categoryDefault: " sonnet "), "sonnet")
        XCTAssertNil(SubagentModel.resolve(override: nil, categoryDefault: ""))
        XCTAssertNil(SubagentModel.resolve(override: nil, categoryDefault: nil))
    }

    func testLaunchArgumentsAndPrefKeys() {
        XCTAssertEqual(SubagentModel.launchArguments(for: nil), [])
        XCTAssertEqual(SubagentModel.launchArguments(for: "haiku"), ["--model", "haiku"])
        XCTAssertEqual(SubagentCategory.allCases.map(SubagentModel.prefKey(for:)),
                       ["model.task", "model.bug", "model.feature", "model.helper"])
    }
}
