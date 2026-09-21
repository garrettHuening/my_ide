import XCTest
@testable import CCHMemory

/// A repo that gains an `origin` after it already has memories must keep the same project row.
/// A second row would strand the memories and orphan the bug ledger for good: the append-only
/// triggers forbid rewriting `bugs.project_id`, so those rows can never be moved across.
final class ProjectAdoptionTests: MemoryTestCase {
    private func resolved(_ key: String, root: String = "/src/late", name: String = "late") -> ResolvedProject {
        ResolvedProject(key: key, name: name, root: root, branch: "main")
    }

    func testRemoteKeyIsDistinguishedFromPathKey() {
        XCTAssertTrue(ProjectKey.isRemoteKey("github.com/me/app"))
        XCTAssertTrue(ProjectKey.isRemoteKey("gitlab.example.com:22/me/app"))
        XCTAssertFalse(ProjectKey.isRemoteKey("/Users/me/Code/app"))
        XCTAssertFalse(ProjectKey.isRemoteKey("/"))
    }

    func testAddingAnOriginAdoptsThePathKeyedProject() throws {
        let before = try store.project(for: resolved("/src/late"))
        try write(.learning, "written before the remote", "body", projectID: before.id)

        let after = try store.project(for: resolved("github.com/me/late"))

        XCTAssertEqual(after.id, before.id, "adding an origin must not create a second project")
        XCTAssertEqual(after.key, "github.com/me/late", "the row should be rekeyed to the shared remote")
        XCTAssertEqual(after.root, "/src/late")
        XCTAssertEqual(try store.projects().filter { $0.root == "/src/late" }.count, 1)
    }

    func testMemoriesAndBugsSurviveTheRekey() throws {
        let before = try store.project(for: resolved("/src/late"))
        let memory = try write(.learning, "kept", "body", projectID: before.id)
        let bug = try store.openBug(projectID: before.id, title: "b", symptom: "s", featureID: nil)

        let after = try store.project(for: resolved("github.com/me/late"))

        XCTAssertEqual(try store.memory(id: memory.id)?.projectID, after.id)
        XCTAssertEqual(try store.bug(projectID: after.id, number: bug.number)?.id, bug.id)
    }

    func testRemovingTheOriginDoesNotDowngradeTheKey() throws {
        let remote = try store.project(for: resolved("github.com/me/late"))

        // A checkout that can no longer read `origin` resolves by path again. It must reuse the
        // row without replacing the shared key with a path local to this machine.
        let fallback = try store.project(for: resolved("/src/late"))

        XCTAssertEqual(fallback.id, remote.id)
        XCTAssertEqual(fallback.key, "github.com/me/late")
        XCTAssertEqual(try store.projects().filter { $0.root == "/src/late" }.count, 1)
    }

    func testUnrelatedRootsStaySeparateProjects() throws {
        let one = try store.project(for: resolved("github.com/me/one", root: "/src/one", name: "one"))
        let two = try store.project(for: resolved("github.com/me/two", root: "/src/two", name: "two"))

        XCTAssertNotEqual(one.id, two.id)
        XCTAssertEqual(one.key, "github.com/me/one")
        XCTAssertEqual(two.key, "github.com/me/two")
    }
}
