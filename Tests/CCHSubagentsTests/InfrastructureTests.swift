import XCTest
@testable import CCHSubagents

final class TrustTests: XCTestCase {
    func testTrustPromptDetectedThroughEscapeSequences() {
        let screen = "\u{1b}[1C❯\u{1b}[1CNo,\u{1b}[1Cexit\r\n\u{1b}[3CYes,\u{1b}[1CI\u{1b}[1Ctrust\u{1b}[1Cthis\u{1b}[1Cfolder\u{1b}[0m"
        XCTAssertTrue(ClaudeTrust.isTrustPrompt(screen))
        XCTAssertFalse(ClaudeTrust.isTrustPrompt("\u{1b}[1CWelcome to Claude Code\u{1b}[0m"))
    }

    func testTrustInheritedFromAncestor() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("claude.json")
        try #"{"projects":{"/Users/me/Code":{"hasTrustDialogAccepted":true},"/Users/me/Other":{"hasTrustDialogAccepted":false}}}"#
            .write(to: config, atomically: true, encoding: .utf8)
        XCTAssertTrue(ClaudeTrust.isTrusted("/Users/me/Code/app/sub", configPath: config.path))
        XCTAssertFalse(ClaudeTrust.isTrusted("/Users/me/Other/app", configPath: config.path))
        XCTAssertFalse(ClaudeTrust.isTrusted("/Users/me", configPath: config.path))
    }
}

final class RPCTests: XCTestCase {
    func testRequestReplyAndEventRoundTrips() throws {
        let request = try XCTUnwrap(RPC.parseRequest(RPC.request("app.merge", ["id": 7])))
        XCTAssertEqual(request.method, "app.merge")
        XCTAssertEqual(request.params["id"] as? Int, 7)

        guard case .success(let result) = RPC.parseReply(RPC.ok(["text": "hi"])) else { return XCTFail() }
        XCTAssertEqual((result as? [String: Any])?["text"] as? String, "hi")
        guard case .failure(let error) = RPC.parseReply(RPC.failure("nope")) else { return XCTFail() }
        XCTAssertEqual(error.message, "nope")

        let event = try XCTUnwrap(RPC.parseEvent(RPC.event("deliverToMain", ["sessionID": 3])))
        XCTAssertEqual(event.type, "deliverToMain")
        XCTAssertEqual(event.fields["sessionID"] as? Int, 3)
    }

    func testSnapshotEncodingRoundTrip() {
        let s = makeSubagent(id: 4, category: .feature, state: .complete, groupID: 2, index: 1)
        let snapshot = SubagentSnapshot(subagent: s, groupName: "theme", report: nil, note: "n", hidden: false,
                                        hasCommits: true, isDirty: false, hostAlive: true)
        let decoded = SubagentSnapshot.decode(SubagentSnapshot.encode([snapshot]))
        XCTAssertEqual(decoded, [snapshot])
        XCTAssertEqual(decoded.first?.gateSubagent.mergeIndex, 1)
    }
}

final class AgentsDBTests: XCTestCase {
    func testInsertSaveGroupsReportsPrefs() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try AgentsDB(path: path)

        var s = Subagent(id: 0, sessionID: 5, sessionDir: "/r", repoRoot: "/r", category: .bug, title: "Fix", brief: "b",
                         model: "haiku", claudeSessionID: "uuid", worktreePath: "/w", branch: "cch/bug/1-fix", baseCommit: "abc")
        let id = try db.insert(s)
        s = try XCTUnwrap(try db.subagent(id: id))
        XCTAssertEqual(s.model, "haiku")
        s.phase = SubagentPhase(.merging, .awaitingMain)
        s.mergeTip = "def"
        try db.save(s)
        XCTAssertEqual(try db.subagent(id: id)?.phase, SubagentPhase(.merging, .awaitingMain))
        XCTAssertEqual(try db.subagent(id: id)?.mergeTip, "def")

        let group = try XCTUnwrap(try db.group(sessionID: 5, name: "theme", create: true))
        try db.applyOrder(groupID: group.id, [id: 1])
        XCTAssertEqual(try db.members(groupID: group.id).map(\.id), [id])
        try db.removeFromGroup(id)
        XCTAssertTrue(try db.members(groupID: group.id).isEmpty)

        try db.addReport(subagentID: id, summary: "half done", done: ["a"], next: ["b"])
        XCTAssertEqual(try db.latestReport(subagentID: id)?.next, ["b"])

        XCTAssertTrue(try db.autoResume())
        try db.setPref(SubagentModel.prefKey(for: .bug), "opus")
        XCTAssertEqual(try db.defaultModel(for: .bug), "opus")
        XCTAssertNil(try db.defaultModel(for: .task))

        try db.setNote(id, "note")
        XCTAssertEqual(try db.note(id), "note")
    }
}

final class PromptTests: XCTestCase {
    func testPromptsMentionToolsAndBranch() {
        XCTAssertTrue(SubagentPrompts.systemRules(category: .bug, branch: "cch/bug/1-x").contains("mcp__plugin_cch-sub_cch__mark_complete"))
        var s = makeSubagent(id: 9)
        s.branch = "cch/task/9-x"
        s.baseCommit = "abcdef123"
        let merge = SubagentPrompts.mergeRequest(subagent: s, summary: "did it", commits: "abc fix", diffStat: "1 file")
        XCTAssertTrue(merge.contains("git merge --no-ff cch/task/9-x"))
        XCTAssertTrue(merge.contains("mark_merged(id: 9"))
        let nudge = SubagentPrompts.continueNudge(report: StatusReport(subagentID: 9, at: Date(), summary: "halfway", done: ["a"], next: ["b"]),
                                                  commits: "", uncommitted: ["x.swift"])
        XCTAssertTrue(nudge.contains("halfway") && nudge.contains("Next: b") && nudge.contains("x.swift"))
    }
}
