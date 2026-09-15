import XCTest
@testable import CCHMemory

final class DreamingTests: MemoryTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testIsDue() {
        XCTAssertTrue(Dreaming.isDue(enabled: true, lastSucceeded: nil, runningSince: nil, changedSinceLast: 3, now: now))
        XCTAssertFalse(Dreaming.isDue(enabled: false, lastSucceeded: nil, runningSince: nil, changedSinceLast: 3, now: now))
        XCTAssertFalse(Dreaming.isDue(enabled: true, lastSucceeded: nil, runningSince: nil, changedSinceLast: 0, now: now))
        XCTAssertFalse(Dreaming.isDue(enabled: true, lastSucceeded: now.addingTimeInterval(-3600), runningSince: nil, changedSinceLast: 3, now: now))
        XCTAssertTrue(Dreaming.isDue(enabled: true, lastSucceeded: now.addingTimeInterval(-7 * 3600), runningSince: nil, changedSinceLast: 3, now: now))
        XCTAssertFalse(Dreaming.isDue(enabled: true, lastSucceeded: nil, runningSince: now.addingTimeInterval(-600), changedSinceLast: 3, now: now))
    }

    func testCandidatesSkipSessionsBugLearningsAndSuperseded() throws {
        let feature = try write(.feature, "Session import", "Imports sessions from the state directory.")
        let related = try write(.architecture, "SessionStore", "Stores imported sessions in SQLite.", links: [(feature.id, .relatesTo)])
        try write(.session, "Session 2026-09-14 · app · import", "Worked on session import.", source: .session)
        let bug = try store.openBug(projectID: project.id, title: "Dupes", symptom: "twice", featureID: feature.id)
        _ = try store.addBugLearning(projectID: project.id, number: bug.number, text: "Session import purge learning", sessionID: nil)
        let old = try write(.learning, "Old import note", "Import used to rescan everything.")
        let kept = try write(.learning, "Import note", "Import rescans only changed folders.")
        try store.supersede(old.id, by: kept.id)

        let candidates = try store.dreamCandidates(projectID: project.id, since: .distantPast)
        let kinds = Set(candidates.map(\.memory.kind))
        XCTAssertFalse(kinds.contains(.session))
        XCTAssertFalse(kinds.contains(.bugLearning))
        XCTAssertFalse(candidates.contains { $0.memory.id == old.id })
        let featureCandidate = try XCTUnwrap(candidates.first { $0.memory.id == feature.id })
        XCTAssertTrue(featureCandidate.related.contains { $0.id == related.id })
        XCTAssertEqual(featureCandidate.lastVersion?.version, 1)
        XCTAssertTrue(try store.dreamCandidates(projectID: project.id, since: Date().addingTimeInterval(60)).isEmpty)
    }

    func testFeatureBumpRequiresChangeAndReason() throws {
        let feature = try write(.feature, "Folders", "Sessions can be grouped into folders.")
        XCTAssertThrowsError(try store.bumpFeatureVersion(featureID: feature.id, reason: "nothing changed"))
        _ = try store.updateMemory(id: feature.id, title: nil, body: "Sessions can be grouped into folders and dragged between them.")
        XCTAssertThrowsError(try store.bumpFeatureVersion(featureID: feature.id, reason: " "))
        let v2 = try store.bumpFeatureVersion(featureID: feature.id, reason: "drag between folders added")
        XCTAssertEqual(v2.version, 2)
        XCTAssertEqual(try store.currentFeatureVersion(featureID: feature.id), 2)
        let api = try write(.api, "Some API", "x")
        XCTAssertThrowsError(try store.bumpFeatureVersion(featureID: api.id, reason: "r"))
    }

    func testDreamRecords() throws {
        let id = try store.startDream(projectID: project.id, since: .distantPast, candidates: 4, model: "haiku")
        XCTAssertEqual(try store.lastDream(projectID: project.id, status: "running")?.id, id)
        try store.finishDream(id: id, succeeded: true, costUSD: 0.2, summary: "Dreamed: 1 merged", error: nil)
        XCTAssertNotNil(try store.lastDream(projectID: project.id, status: "succeeded")?.finishedAt)
    }

    func testPromptCarriesConservativeRuleVerbatim() {
        XCTAssertTrue(Dreaming.prompt(projectName: "app", candidateCount: 3).contains(Dreaming.conservativeBumpRule))
        XCTAssertTrue(Dreaming.conservativeBumpRule.contains("When unsure, do not bump"))
    }
}

final class ToolsetTests: MemoryTestCase {
    private func ctx(_ toolset: Toolset) -> ToolContext {
        ToolContext(store: store, console: console, project: project, branch: nil, sessionID: nil, source: "test", toolset: toolset)
    }

    func testToolsetsExposeOnlyTheirTools() {
        let names: (Toolset) -> Set<String> = { Set(MemoryTools.definitions(for: $0).compactMap { $0["name"] as? String }) }
        XCTAssertFalse(names(.main).contains("feature_bump_version"))
        XCTAssertTrue(names(.dream).isSuperset(of: ["dream_candidates", "memory_supersede", "feature_bump_version"]))
        XCTAssertFalse(names(.dream).contains("memory_write"))
        XCTAssertFalse(names(.sweep).contains("bug_open"))
        XCTAssertEqual(names(.docs), ["memory_search", "memory_get", "memory_write", "memory_link", "memory_flag_conflict"])
        XCTAssertThrowsError(try MemoryTools.call("feature_bump_version", arguments: ["feature": "M1", "reason": "r"], context: ctx(.main)))
    }

    func testForcedSources() throws {
        _ = try MemoryTools.call("memory_write", arguments: ["kind": "api", "title": "GET /notes", "body": "Lists notes.", "source": "code"], context: ctx(.docs))
        _ = try MemoryTools.call("memory_write", arguments: ["kind": "script", "title": "deploy", "body": "Command: make deploy", "source": "user"], context: ctx(.sweep))
        XCTAssertEqual(try store.memories(projectID: project.id, kind: .api).first?.source, .doc)
        XCTAssertEqual(try store.memories(projectID: project.id, kind: .script).first?.source, .code)
    }

    func testDreamToolsThroughCall() throws {
        let a = try write(.learning, "Terminal inset A", "Top inset of 8px avoids clipping.")
        let b = try write(.learning, "Terminal inset B", "SwiftTerm first row clips without padding.")
        let listing = try MemoryTools.call("dream_candidates", arguments: [:], context: ctx(.dream))
        XCTAssertTrue(listing.contains("[M\(a.id)]") && listing.contains("[M\(b.id)]"))
        _ = try MemoryTools.call("memory_supersede", arguments: ["old": "M\(b.id)", "kept": "M\(a.id)", "reason": "same fact"], context: ctx(.dream))
        XCTAssertEqual(try store.memory(id: b.id)?.supersededBy, a.id)
        XCTAssertThrowsError(try MemoryTools.call("memory_supersede", arguments: ["old": "M\(a.id)", "kept": "M\(b.id)", "reason": "x"], context: ctx(.dream)))
        XCTAssertEqual(try console.recent(domains: ["dreaming"]).count, 1)
    }

    func testIngestionRecords() throws {
        let id = try store.startIngestion(projectID: project.id, source: "https://docs.example.com")
        try write(.api, "GET /x", "Returns x.", source: .doc)
        XCTAssertEqual(try store.finishIngestion(id: id, projectID: project.id, succeeded: true, costUSD: 0.1, error: nil), 1)
        let args = DocsIngestion.arguments(prompt: "p", pluginDirectory: "/p", model: "sonnet", allowWeb: true)
        XCTAssertTrue(args.contains("WebFetch"))
        XCTAssertTrue(args.contains("mcp__plugin_cch-docs_cch"))
    }
}
