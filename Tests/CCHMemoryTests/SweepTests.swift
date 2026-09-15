import XCTest
@testable import CCHMemory

final class SweepTests: MemoryTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(status: SweepStatus, startedAgo: TimeInterval, commit: String? = "abc") -> SweepRecord {
        SweepRecord(id: 1, projectID: 1, commitSHA: commit, mode: .full, status: status,
                    startedAt: now.addingTimeInterval(-startedAgo), finishedAt: now.addingTimeInterval(-startedAgo + 60))
    }

    func testPolicy() {
        XCTAssertEqual(SweepPolicy.decide(lastSucceeded: nil, running: nil, commitsSinceLast: nil, autoSweep: true, now: now), .full)
        XCTAssertEqual(SweepPolicy.decide(lastSucceeded: nil, running: nil, commitsSinceLast: nil, autoSweep: false, now: now), .skip)
        XCTAssertEqual(SweepPolicy.decide(lastSucceeded: nil, running: record(status: .running, startedAgo: 120), commitsSinceLast: nil, autoSweep: true, now: now), .skip)
        XCTAssertEqual(SweepPolicy.decide(lastSucceeded: nil, running: record(status: .running, startedAgo: 7200), commitsSinceLast: nil, autoSweep: true, now: now), .full)

        let recent = record(status: .succeeded, startedAgo: 3600)
        XCTAssertEqual(SweepPolicy.decide(lastSucceeded: recent, running: nil, commitsSinceLast: 19, autoSweep: true, now: now), .skip)
        XCTAssertEqual(SweepPolicy.decide(lastSucceeded: recent, running: nil, commitsSinceLast: 20, autoSweep: true, now: now), .incremental(sinceCommit: "abc"))
        let old = record(status: .succeeded, startedAgo: 8 * 86_400)
        XCTAssertEqual(SweepPolicy.decide(lastSucceeded: old, running: nil, commitsSinceLast: 0, autoSweep: true, now: now), .incremental(sinceCommit: "abc"))
        XCTAssertEqual(SweepPolicy.decide(lastSucceeded: record(status: .succeeded, startedAgo: 8 * 86_400, commit: nil), running: nil, commitsSinceLast: nil, autoSweep: true, now: now), .full)
    }

    func testSweepRecordsAndPrefs() throws {
        XCTAssertTrue(try store.autoSweep())
        XCTAssertEqual(try store.backgroundModel(), "sonnet")
        try store.setPref(MemoryStore.autoSweepKey, "0")
        try store.setPref(MemoryStore.backgroundModelKey, "haiku")
        XCTAssertFalse(try store.autoSweep())
        XCTAssertEqual(try store.backgroundModel(), "haiku")

        let id = try store.startSweep(projectID: project.id, commit: "abc", mode: .full, model: "haiku")
        XCTAssertEqual(try store.lastSweep(projectID: project.id, status: .running)?.id, id)
        try write(.script, "test", "Command: swift test\nRuns unit tests.")
        try store.finishSweep(id: id, projectID: project.id, succeeded: true, costUSD: 0.12, error: nil)
        XCTAssertNil(try store.lastSweep(projectID: project.id, status: .running))
        XCTAssertEqual(try store.lastSweep(projectID: project.id, status: .succeeded)?.commitSHA, "abc")
        XCTAssertEqual(try store.sweepMemoriesAdded(sweepID: id), 1)
    }

    func testScriptCommandParsing() {
        XCTAssertEqual(ScriptCommand.command(in: "Command: scripts/bundle.sh --run\nBuilds the app."), "scripts/bundle.sh --run")
        XCTAssertEqual(ScriptCommand.command(in: "command: `npm run dev`"), "npm run dev")
        XCTAssertNil(ScriptCommand.command(in: "Builds the app.\nCommand: x"))
        XCTAssertEqual(ScriptCommand.description(in: "Command: make\nBuilds everything.\nUse before release."), "Builds everything.\nUse before release.")
    }

    func testPromptAndArguments() {
        let full = SweepPrompt.text(mode: .full, changedFiles: [])
        XCTAssertTrue(full.contains("MODE: full"))
        XCTAssertTrue(full.contains("Command: <exact command"))
        let incremental = SweepPrompt.text(mode: .incremental(sinceCommit: "abc"), changedFiles: ["Sources/A.swift"])
        XCTAssertTrue(incremental.contains("commit abc"))
        XCTAssertTrue(incremental.contains("Sources/A.swift"))

        let args = SweepPrompt.arguments(prompt: "p", pluginDirectory: "/plug", model: "sonnet")
        XCTAssertEqual(Array(args.prefix(2)), ["-p", "p"])
        XCTAssertTrue(args.contains("mcp__plugin_cch-sweep_cch"))
        XCTAssertTrue(args.contains("--no-session-persistence"))
        XCTAssertEqual(args.last, "NotebookEdit")
    }
}
