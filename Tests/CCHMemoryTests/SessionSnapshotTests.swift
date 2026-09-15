import XCTest
@testable import CCHMemory

final class SessionSnapshotTests: MemoryTestCase {
    private func jsonl(_ entries: [[String: Any]]) -> String {
        entries.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }.joined(separator: "\n")
    }

    func testCondenseKeepsDialogueAndTruncatesTools() {
        let long = String(repeating: "x", count: 1000)
        let text = TranscriptCondenser.condense(jsonl: jsonl([
            ["type": "user", "message": ["content": "Fix the import bug"]],
            ["type": "assistant", "message": ["content": [["type": "text", "text": "Looking at [M4]."],
                                                          ["type": "tool_use", "name": "Read", "input": ["file_path": "a.swift"]]]]],
            ["type": "user", "message": ["content": [["type": "tool_result", "content": long]]]],
            ["type": "system", "message": ["content": "ignored"]]
        ]))
        XCTAssertTrue(text.contains("USER: Fix the import bug"))
        XCTAssertTrue(text.contains("CLAUDE: Looking at [M4]."))
        XCTAssertTrue(text.contains("[tool Read] {\"file_path\":\"a.swift\"}"))
        XCTAssertTrue(text.contains("[result] " + String(repeating: "x", count: 300) + "…"))
        XCTAssertFalse(text.contains("ignored"))
    }

    func testCondenseKeepsTheMostRecentPartWhenTooLong() {
        let entries: [[String: Any]] = (0..<2000).map { ["type": "user", "message": ["content": "message \($0) " + String(repeating: "y", count: 100)]] }
        let text = TranscriptCondenser.condense(jsonl: jsonl(entries))
        XCTAssertTrue(text.hasPrefix("[…earlier conversation omitted…]"))
        XCTAssertTrue(text.contains("message 1999"))
        XCTAssertFalse(text.contains("message 0 "))
    }

    func testReferences() {
        let refs = TranscriptCondenser.references(in: "Recorded [M12] and [M7]; see BUG-3, not M99 or XBUG-4")
        XCTAssertEqual(refs.memoryIDs, [12, 7])
        XCTAssertEqual(refs.bugNumbers, [3])
    }

    func testParseAndTitle() {
        let parsed = SessionSnapshot.parse(reply: "# Core memory hooks\n\n## Goal\n- wire hooks")
        XCTAssertEqual(parsed?.focus, "Core memory hooks")
        XCTAssertEqual(parsed?.body, "## Goal\n- wire hooks")
        XCTAssertNil(SessionSnapshot.parse(reply: "only a title"))
        let date = Date(timeIntervalSince1970: 1_789_430_400) // 2026-09-15 UTC
        XCTAssertTrue(SessionSnapshot.title(focus: "Hooks", projectName: "app", date: date).hasSuffix(" · app · Hooks"))
    }

    func testSaveUpsertsOneMemoryPerSessionAndLinksTouchedMemories() throws {
        let retrieved = try write(.feature, "Session import", "Imports sessions.")
        let cited = try write(.api, "SessionStore.setStatus", "Sets status.")
        try store.logRetrieval(projectID: project.id, sessionID: "sess-1", prompt: "p", memoryIDs: [retrieved.id], bugIDs: [])

        let first = try XCTUnwrap(SessionSnapshot.save(store: store, projectID: project.id, sessionID: "sess-1", projectName: "app",
                                                       reply: "Import fixes\n## Goal\n- fix import", transcript: "used [M\(cited.id)]", branch: "main"))
        XCTAssertEqual(first.kind, .session)
        let linked = Set(try store.links(of: first.id).filter { $0.relation == .touchedIn }.map(\.toID))
        XCTAssertEqual(linked, [retrieved.id, cited.id])

        let second = try XCTUnwrap(SessionSnapshot.save(store: store, projectID: project.id, sessionID: "sess-1", projectName: "app",
                                                        reply: "Import fixes, part two\n## Goal\n- fix import\n## Done\n- purge", transcript: "", branch: "main"))
        XCTAssertEqual(second.id, first.id)
        XCTAssertTrue(second.body.contains("## Done"))
        XCTAssertEqual(try store.latestSessionMemory(projectID: project.id)?.id, first.id)
    }
}
