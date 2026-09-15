import XCTest
@testable import CCHMemory

final class MemoryStoreTests: MemoryTestCase {
    func testWriteCreatesMemoryAndFeatureVersionOne() throws {
        let feature = try write(.feature, "Session import", "Scans ~/.claude/projects and creates sessions.")
        XCTAssertEqual(feature.kind, .feature)
        XCTAssertEqual(try store.currentFeatureVersion(featureID: feature.id), 1)
        XCTAssertEqual(try store.activeMemoryCount(projectID: project.id), 1)
    }

    func testExactDuplicateReturnsExisting() throws {
        let first = try store.writeMemory(projectID: project.id, kind: .api, title: "SessionStore.setStatus", body: "Updates status.", source: .code)
        let second = try store.writeMemory(projectID: project.id, kind: .api, title: "SessionStore.setStatus", body: "Updates status.", source: .code)
        XCTAssertFalse(first.duplicate)
        XCTAssertTrue(second.duplicate)
        XCTAssertEqual(first.memory.id, second.memory.id)
    }

    func testNearDuplicateBySimilarityReturnsExisting() throws {
        let first = try store.writeMemory(projectID: project.id, kind: .learning, title: "Terminal inset",
                                          body: "SwiftTerm first row clips without an 8px top inset", source: .session)
        let second = try store.writeMemory(projectID: project.id, kind: .learning, title: "terminal inset",
                                           body: "swiftterm first row clips without an 8px top inset!", source: .session)
        XCTAssertTrue(second.duplicate)
        XCTAssertEqual(second.memory.id, first.memory.id)
    }

    func testUpdateChangesBodyButNeverBumpsFeatureVersion() throws {
        let feature = try write(.feature, "Folders", "Sessions can be grouped into folders.")
        let updated = try store.updateMemory(id: feature.id, title: nil, body: "Sessions can be grouped into reorderable folders.")
        XCTAssertEqual(updated.body, "Sessions can be grouped into reorderable folders.")
        XCTAssertEqual(try store.currentFeatureVersion(featureID: feature.id), 1)
        XCTAssertEqual(try store.ftsMemories(projectIDs: [project.id], match: "\"reorderable\"", limit: 5), [feature.id])
    }

    func testSupersededMemoriesAreHiddenFromSearchAndRejectUpdates() throws {
        let old = try write(.api, "Old API", "fetchSessions returns all sessions")
        let new = try write(.api, "New API", "loadSessions returns imported sessions only")
        try store.supersede(old.id, by: new.id)
        XCTAssertEqual(try store.ftsMemories(projectIDs: [project.id], match: "\"sessions\"", limit: 5), [new.id])
        XCTAssertThrowsError(try store.updateMemory(id: old.id, title: nil, body: "x")) { error in
            XCTAssertEqual(error as? MemoryError, .superseded(id: old.id, by: new.id))
        }
    }

    func testBugNumbersArePerProject() throws {
        let other = try store.project(for: ResolvedProject(key: "github.com/me/other", name: "other", root: "/src/other", branch: nil))
        XCTAssertEqual(try store.openBug(projectID: project.id, title: "A", symptom: "a", featureID: nil).number, 1)
        XCTAssertEqual(try store.openBug(projectID: project.id, title: "B", symptom: "b", featureID: nil).number, 2)
        XCTAssertEqual(try store.openBug(projectID: other.id, title: "C", symptom: "c", featureID: nil).number, 1)
    }

    func testBugRecordsFeatureVersionAndFixesOnlyOnce() throws {
        let feature = try write(.feature, "Import", "Imports sessions.")
        let bug = try store.openBug(projectID: project.id, title: "Duplicates", symptom: "Sessions appear twice", featureID: feature.id)
        XCTAssertEqual(bug.featureVersion, 1)
        let fixed = try store.fixBug(projectID: project.id, number: bug.number, rootCause: "No purge", fixSummary: "Purge old source", commit: "abc123")
        XCTAssertEqual(fixed.status, .fixed)
        XCTAssertEqual(fixed.commitSHA, "abc123")
        XCTAssertThrowsError(try store.fixBug(projectID: project.id, number: bug.number, rootCause: "x", fixSummary: "y", commit: nil))
    }

    func testTriggersKeepBugsAppendOnlyEvenForRawSQL() throws {
        let bug = try store.openBug(projectID: project.id, title: "Crash", symptom: "Crashes on launch", featureID: nil)
        XCTAssertThrowsError(try store.db.run("DELETE FROM bugs WHERE id = ?", [bug.id])) { error in
            XCTAssertTrue((error as? SQLiteError)?.message.contains("append-only") == true)
        }
        XCTAssertThrowsError(try store.db.run("UPDATE bugs SET title = 'rewritten' WHERE id = ?", [bug.id]))
        _ = try store.fixBug(projectID: project.id, number: bug.number, rootCause: "r", fixSummary: "f", commit: nil)
        XCTAssertThrowsError(try store.db.run("UPDATE bugs SET fix_summary = 'rewritten' WHERE id = ?", [bug.id]))
        XCTAssertEqual(try store.bug(id: bug.id)?.fixSummary, "f")
    }

    func testBugLearningsAreFrozen() throws {
        let bug = try store.openBug(projectID: project.id, title: "Crash", symptom: "Crashes on launch", featureID: nil)
        let learning = try store.addBugLearning(projectID: project.id, number: bug.number, text: "Quarantine flag stops launch.", sessionID: "s1")
        XCTAssertEqual(learning.kind, .bugLearning)
        XCTAssertThrowsError(try store.updateMemory(id: learning.id, title: nil, body: "changed"))
        XCTAssertThrowsError(try store.db.run("UPDATE memories SET body = 'changed' WHERE id = ?", [learning.id]))
        XCTAssertThrowsError(try store.db.run("DELETE FROM memories WHERE id = ?", [learning.id]))
        XCTAssertEqual(try store.bugLearnings(bugID: bug.id).map(\.id), [learning.id])
    }

    func testRegressionLinks() throws {
        let old = try store.openBug(projectID: project.id, title: "Old", symptom: "s", featureID: nil)
        let new = try store.openBug(projectID: project.id, title: "New", symptom: "s", featureID: nil)
        try store.linkRegression(projectID: project.id, newNumber: new.number, oldNumber: old.number)
        XCTAssertEqual(try store.regressions(ofBugID: new.id), [old.number])
        XCTAssertThrowsError(try store.linkRegression(projectID: project.id, newNumber: new.number, oldNumber: new.number))
    }

    func testOpenBugRejectsNonFeatureMemory() throws {
        let api = try write(.api, "Some API", "Does things")
        XCTAssertThrowsError(try store.openBug(projectID: project.id, title: "t", symptom: "s", featureID: api.id))
    }

    func testStrictnessDefaultsToBalanced() throws {
        XCTAssertEqual(try store.strictness(), .balanced)
        try store.setStrictness(.strict)
        XCTAssertEqual(try store.strictness(), .strict)
    }
}
