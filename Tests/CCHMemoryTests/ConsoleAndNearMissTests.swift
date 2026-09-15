import XCTest
@testable import CCHMemory

final class ConsoleAndNearMissTests: MemoryTestCase {
    func testCorrectionDetector() {
        for prompt in ["No, that's the old API", "nope", "Actually the lane is called release", "That's not right, it uses GRDB",
                       "you misunderstood the question", "hmm that is not how import works", "That function doesn't exist"] {
            XCTAssertTrue(CorrectionDetector.looksLikeCorrection(prompt), prompt)
        }
        for prompt in ["Now add a settings screen", "note that we use SQLite", "Nothing else, thanks", "know any good tests?", "Explain the import"] {
            XCTAssertFalse(CorrectionDetector.looksLikeCorrection(prompt), prompt)
        }
    }

    func testNearMissIsLoggedWhenCorrectingAGroundedAnswer() throws {
        let local = try store.project(for: ProjectKey.resolve(directory: tempDir.path))
        let m = try store.writeMemory(projectID: local.id, kind: .api, title: "Release lane", body: "fastlane beta ships TestFlight builds", source: .code).memory
        _ = HookHandlers.userPromptSubmit(payload: ["prompt": "how do we ship a testflight release lane", "cwd": tempDir.path, "session_id": "s"],
                                          store: store, console: console)
        _ = HookHandlers.userPromptSubmit(payload: ["prompt": "No, we renamed that lane to release last month", "cwd": tempDir.path, "session_id": "s"],
                                          store: store, console: console)
        let entries = try console.recent(domains: ["memory.nearmiss"])
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].message.contains("M\(m.id)"))
        XCTAssertTrue(entries[0].dataJSON?.contains("renamed that lane") == true)
    }

    func testConsoleFiltersAndDomains() throws {
        try console.append(domain: "hub", severity: .debug, source: "hub", message: "launch")
        try console.append(domain: "sweep", severity: .warning, source: "hub", message: "slow sweep")
        try console.append(domain: "sweep", severity: .error, source: "hub", message: "sweep failed")
        XCTAssertEqual(try console.domains(), ["hub", "sweep"])
        XCTAssertEqual(try console.recent(minimumSeverity: .warning).map(\.message), ["sweep failed", "slow sweep"])
        XCTAssertEqual(try console.recent(text: "launch").count, 1)
        XCTAssertThrowsError(try console.append(domain: " ", severity: .info, source: "x", message: "m"))
    }
}
