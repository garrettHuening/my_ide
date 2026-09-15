import XCTest
@testable import CCHMemory

final class MemoryToolsTests: MemoryTestCase {
    func testWriteThenSearchAndGet() throws {
        let arch = try write(.architecture, "TerminalRegistry", "Caches one terminal per session.")
        let written = try MemoryTools.call("memory_write", arguments: [
            "kind": "learning", "title": "Terminal top inset",
            "body": "SwiftTerm clips the first row unless the container has an 8px top inset.",
            "links": [["to": "M\(arch.id)", "relation": "relates_to"]]
        ], context: context())
        XCTAssertTrue(written.hasPrefix("Recorded [M"))

        let search = try MemoryTools.call("memory_search", arguments: ["query": "terminal first row clipped inset"], context: context())
        XCTAssertTrue(search.contains("Terminal top inset"))

        let id = written.split(separator: "[")[1].split(separator: "]")[0]
        let detail = try MemoryTools.call("memory_get", arguments: ["id": String(id)], context: context())
        XCTAssertTrue(detail.contains("-relates_to-> [M\(arch.id)] TerminalRegistry"))
    }

    func testWriteRejectsFrozenKindAndBadLinks() {
        XCTAssertThrowsError(try MemoryTools.call("memory_write", arguments: ["kind": "bug-learning", "title": "t", "body": "b"], context: context()))
        XCTAssertThrowsError(try MemoryTools.call("memory_write", arguments: ["kind": "api", "title": "t", "body": "b",
                                                                              "links": [["to": "M999", "relation": "part_of"]]], context: context()))
        XCTAssertThrowsError(try MemoryTools.call("memory_write", arguments: ["kind": "api", "title": "t"], context: context()))
    }

    func testBugLifecycleThroughTools() throws {
        let feature = try write(.feature, "Session import", "Imports sessions.")
        let opened = try MemoryTools.call("bug_open", arguments: ["title": "Duplicate sessions", "symptom": "Sessions appear twice after changing state dir", "feature": "M\(feature.id)"], context: context())
        XCTAssertTrue(opened.hasPrefix("Opened [BUG-1]"))
        _ = try MemoryTools.call("bug_fix", arguments: ["bug": "BUG-1", "root_cause": "Old imports not purged", "fix_summary": "Purge imports from other sources"], context: context())
        _ = try MemoryTools.call("bug_learning", arguments: ["bug": "BUG-1", "text": "Tag imports with their source directory."], context: context())

        _ = try store.updateMemory(id: feature.id, title: nil, body: "Imports sessions, tagged by source.")
        try store.db.run("INSERT INTO feature_versions(feature_id, version, description, reason, created_at) VALUES (?, 2, 'tagged', 'semantic change', ?)", [feature.id, Date()])
        _ = try MemoryTools.call("bug_open", arguments: ["title": "Duplicates again", "symptom": "Sessions appear twice after changing state dir", "feature": "M\(feature.id)"], context: context())

        let similar = try MemoryTools.call("bug_similar", arguments: ["symptom": "sessions twice after state dir change", "feature": "M\(feature.id)"], context: context())
        XCTAssertTrue(similar.contains("[BUG-1] fixed against M\(feature.id) v1"))
        XCTAssertTrue(similar.contains("(feature is now v2)"))

        _ = try MemoryTools.call("bug_link_regression", arguments: ["bug": "BUG-2", "regression_of": "BUG-1"], context: context())
        let detail = try MemoryTools.call("memory_get", arguments: ["id": "BUG-2"], context: context())
        XCTAssertTrue(detail.contains("Regression of: BUG-1"))
        let first = try MemoryTools.call("memory_get", arguments: ["id": "BUG-1"], context: context())
        XCTAssertTrue(first.contains("Tag imports with their source directory."))
        XCTAssertTrue(first.contains("fixed against v1 (now v2)"))
    }

    func testConflictAndLogEventGoToConsole() throws {
        _ = try MemoryTools.call("memory_flag_conflict", arguments: ["a": "M1", "b": "M2", "note": "README says 3 args, code takes 4"], context: context())
        _ = try MemoryTools.call("log_event", arguments: ["domain": "deploy", "severity": "error", "message": "S3 upload failed", "data": ["code": 403]], context: context())
        let entries = try console.recent()
        XCTAssertEqual(entries.map(\.domain), ["deploy", "memory.conflict"])
        XCTAssertEqual(entries[0].dataJSON, "{\"code\":403}")
        XCTAssertEqual(try console.recent(minimumSeverity: .error).count, 1)
    }

    func testDefinitionsAreValidJSON() throws {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(["tools": MemoryTools.definitions]))
        XCTAssertEqual(MemoryTools.definitions.count, 12)
    }
}

final class HookHandlersTests: MemoryTestCase {
    private func projectForTempDir() throws -> Project {
        try store.project(for: ProjectKey.resolve(directory: tempDir.path))
    }

    func testUserPromptSubmitInjectsMatchingMemories() throws {
        let local = try projectForTempDir()
        let m = try store.writeMemory(projectID: local.id, kind: .feature, title: "Session import",
                                      body: "Scans the projects folder and creates sessions.", source: .code).memory
        let out = HookHandlers.userPromptSubmit(payload: ["prompt": "why does session import create duplicates?",
                                                          "cwd": tempDir.path, "session_id": "abc"],
                                                store: store, console: console)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        let specific = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["hookEventName"] as? String, "UserPromptSubmit")
        let context = try XCTUnwrap(specific["additionalContext"] as? String)
        XCTAssertTrue(context.contains("[M\(m.id)] feature v1"))
        XCTAssertEqual(try store.lastRetrievalCount(sessionID: "abc"), 1)
    }

    func testFirstPromptWithNoMemoriesExplainsTools() throws {
        let out = HookHandlers.userPromptSubmit(payload: ["prompt": "let's build the settings screen now", "cwd": tempDir.path, "session_id": "new"],
                                                store: store, console: console)
        XCTAssertTrue(out.contains("No core memories match yet"))
        let second = HookHandlers.userPromptSubmit(payload: ["prompt": "and the toolbar layout too please", "cwd": tempDir.path, "session_id": "new"],
                                                   store: store, console: console)
        XCTAssertEqual(second, "")
    }

    func testStopBlocksUncitedLongAnswerOnlyInStrictWithEnoughMemories() throws {
        let local = try projectForTempDir()
        for i in 0..<50 {
            _ = try store.writeMemory(projectID: local.id, kind: .learning, title: "Import fact topic\(i)", body: "Import detail item\(i) value area\(i * 7)", source: .code)
        }
        XCTAssertEqual(try store.activeMemoryCount(projectID: local.id), 50)
        try store.setStrictness(.strict)
        _ = HookHandlers.userPromptSubmit(payload: ["prompt": "explain the import detail values", "cwd": tempDir.path, "session_id": "s"],
                                          store: store, console: console)
        let transcript = tempDir.appendingPathComponent("t.jsonl")
        let lines = [
            ["type": "user", "message": ["role": "user", "content": "explain the import detail values"]],
            ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": String(repeating: "Imports walk folders. ", count: 30)]]]]
        ].map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
        try lines.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let payload: [String: Any] = ["session_id": "s", "cwd": tempDir.path, "transcript_path": transcript.path, "stop_hook_active": false]
        XCTAssertTrue(HookHandlers.stop(payload: payload, store: store, console: console).contains("\"decision\":\"block\""))
        var active = payload
        active["stop_hook_active"] = true
        XCTAssertEqual(HookHandlers.stop(payload: active, store: store, console: console), "")
    }

    func testLastAssistantTextSkipsToolResultsAndStopsAtRealPrompt() throws {
        let transcript = tempDir.appendingPathComponent("t.jsonl")
        let entries: [[String: Any]] = [
            ["type": "user", "message": ["content": "old prompt"]],
            ["type": "assistant", "message": ["content": [["type": "text", "text": "old answer"]]]],
            ["type": "user", "message": ["content": "new prompt"]],
            ["type": "assistant", "message": ["content": [["type": "text", "text": "part one"], ["type": "tool_use", "name": "Read"]]]],
            ["type": "user", "message": ["content": [["type": "tool_result", "content": "file"]]]],
            ["type": "assistant", "message": ["content": [["type": "text", "text": "part two"]]]]
        ]
        try entries.map { String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
            .joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)
        XCTAssertEqual(HookHandlers.lastAssistantText(transcriptPath: transcript.path), "part one\npart two")
    }
}
