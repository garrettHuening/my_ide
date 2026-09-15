import XCTest
@testable import CCHMemory

final class RetrieverTests: MemoryTestCase {
    func testKeywordMatchRanksRelevantMemoryFirst() throws {
        try write(.script, "deploy.sh", "Pushes the web build to S3 and invalidates CloudFront.")
        let importer = try write(.feature, "Session import", "Scans the claude projects folder and imports each session.")
        try write(.design, "Theme colors", "All colors come from Theme.swift.")

        let items = try Retriever(store: store).retrieve(prompt: "session import creates duplicates", projectIDs: [project.id])
        guard case .memory(let top)? = items.first?.ref else { return XCTFail("no memory") }
        XCTAssertEqual(top.id, importer.id)
    }

    func testLinkedArchitectureAndFeatureBugsAreExpanded() throws {
        let arch = try write(.architecture, "SessionStore", "SQLite-backed store for sessions.")
        let feature = try write(.feature, "Session import", "Imports sessions from the state directory.", links: [(arch.id, .partOf)])
        let bug = try store.openBug(projectID: project.id, title: "Unrelated crash", symptom: "Window never appears", featureID: feature.id)

        let items = try Retriever(store: store).retrieve(prompt: "how does session import work", projectIDs: [project.id])
        let keys = items.map(\.ref.key)
        XCTAssertTrue(keys.contains("M\(feature.id)"))
        XCTAssertTrue(keys.contains("M\(arch.id)"))
        XCTAssertTrue(keys.contains("B\(bug.id)"), "recent bugs on a matched feature are included")
        XCTAssertTrue(items.first { $0.ref.key == "M\(arch.id)" }!.viaLink || items.first { $0.ref.key == "M\(arch.id)" }!.score > 0)
    }

    func testProjectScopeExcludesOtherProjects() throws {
        let other = try store.project(for: ResolvedProject(key: "github.com/me/other", name: "other", root: "/o", branch: nil))
        try write(.feature, "Session import elsewhere", "Imports sessions in another app.", projectID: other.id)
        let mine = try write(.feature, "Session import", "Imports sessions.")

        let scoped = try Retriever(store: store).retrieve(prompt: "session import details", projectIDs: [project.id])
        XCTAssertEqual(scoped.map(\.ref.key), ["M\(mine.id)"])
        let all = try Retriever(store: store).retrieve(prompt: "session import details", projectIDs: nil)
        XCTAssertEqual(all.count, 2)
    }

    func testPreviousSessionIsPinnedAndShortPromptsOnlyGetIt() throws {
        let session = try write(.session, "Session 2026-09-14 · app", "Built the memory store; next: hooks.", source: .session)
        try write(.feature, "Hooks", "UserPromptSubmit retrieval hook.")

        let short = try Retriever(store: store).retrieve(prompt: "hi", projectIDs: [project.id], includeSessionMemoryFor: project.id)
        XCTAssertEqual(short.map(\.ref.key), ["M\(session.id)"])
        XCTAssertTrue(short[0].pinned)

        let long = try Retriever(store: store).retrieve(prompt: "what about the hooks work", projectIDs: [project.id], includeSessionMemoryFor: project.id)
        XCTAssertEqual(long.first?.ref.key, "M\(session.id)")
        XCTAssertEqual(long.filter { $0.ref.key == "M\(session.id)" }.count, 1)
    }

    func testLimitIsRespected() throws {
        for i in 0..<20 { try write(.learning, "Session fact topic\(i)", "Session detail item\(i) covers sessions area\(i * 7).") }
        XCTAssertEqual(try Retriever(store: store).retrieve(prompt: "tell me about sessions", projectIDs: [project.id], limit: 5).count, 5)
    }
}

final class GroundingTests: MemoryTestCase {
    func testStrictRelaxesBelowFiftyMemories() {
        XCTAssertEqual(Grounding.effective(.strict, memoryCount: 49), .balanced)
        XCTAssertEqual(Grounding.effective(.strict, memoryCount: 50), .strict)
        XCTAssertEqual(Grounding.effective(.off, memoryCount: 500), .off)
    }

    func testContextBlockCitesMemoriesAndBugsWithRules() throws {
        let feature = try write(.feature, "Session import", "Imports sessions.")
        let bug = try store.openBug(projectID: project.id, title: "Duplicates", symptom: "Sessions twice", featureID: feature.id)
        let items = [RetrievedItem(ref: .memory(feature), score: 1, viaLink: false, pinned: false),
                     RetrievedItem(ref: .bug(bug), score: 0.5, viaLink: true, pinned: false)]
        let block = try XCTUnwrap(Grounding.contextBlock(items: items, projectName: "app", strictness: .balanced,
                                                         featureVersions: [feature.id: 1], toolPrefix: "mcp__x__"))
        XCTAssertTrue(block.hasPrefix("<core-memories project=\"app\" strictness=\"balanced\" count=\"2\">"))
        XCTAssertTrue(block.contains("[M\(feature.id)] feature v1 · code · Session import"))
        XCTAssertTrue(block.contains("[BUG-1] open against M\(feature.id) v1 · Duplicates (linked)"))
        XCTAssertTrue(block.contains("mcp__x__memory_flag_conflict"))
        XCTAssertTrue(block.hasSuffix("</core-memories>"))
        XCTAssertNil(Grounding.contextBlock(items: [], projectName: "app", strictness: .balanced, featureVersions: [:], toolPrefix: ""))
    }

    func testOffHasNoRules() throws {
        let m = try write(.api, "API", "body")
        let block = try XCTUnwrap(Grounding.contextBlock(items: [RetrievedItem(ref: .memory(m), score: 1, viaLink: false, pinned: false)],
                                                         projectName: "app", strictness: .off, featureVersions: [:], toolPrefix: "p_"))
        XCTAssertFalse(block.contains("Rules"))
    }

    func testStrictStopCheck() {
        let long = String(repeating: "The import walks the filesystem. ", count: 20)
        XCTAssertNotNil(Grounding.strictStopReason(strictness: .strict, stopHookActive: false, assistantText: long, retrievedCount: 3))
        XCTAssertNil(Grounding.strictStopReason(strictness: .strict, stopHookActive: false, assistantText: long + " [M4]", retrievedCount: 3))
        XCTAssertNil(Grounding.strictStopReason(strictness: .strict, stopHookActive: true, assistantText: long, retrievedCount: 3))
        XCTAssertNil(Grounding.strictStopReason(strictness: .strict, stopHookActive: false, assistantText: long, retrievedCount: 0))
        XCTAssertNil(Grounding.strictStopReason(strictness: .strict, stopHookActive: false, assistantText: "short", retrievedCount: 3))
        XCTAssertNil(Grounding.strictStopReason(strictness: .balanced, stopHookActive: false, assistantText: long, retrievedCount: 3))
        XCTAssertTrue(Grounding.hasCitation("see [BUG-12]"))
        XCTAssertFalse(Grounding.hasCitation("see M12"))
    }
}
