import XCTest
@testable import CCHSubagents

final class SubagentNamingTests: XCTestCase {
    func testSlugBasics() {
        XCTAssertEqual(SubagentNaming.slug("Add dark mode toggle!"), "add-dark-mode-toggle")
        XCTAssertEqual(SubagentNaming.slug("  Fix: crash on EMPTY folder  "), "fix-crash-on-empty-folder")
        XCTAssertEqual(SubagentNaming.slug("Zelda's Room"), "zelda-s-room")
    }

    func testSlugFallsBackWhenNoASCIIAlphanumerics() {
        XCTAssertEqual(SubagentNaming.slug("日本語"), "subagent")
        XCTAssertEqual(SubagentNaming.slug("!!!"), "subagent")
    }

    func testSlugTruncatesTo32WithoutTrailingDash() {
        XCTAssertEqual(
            SubagentNaming.slug("implement the entire settings screen redesign with tokens"),
            "implement-the-entire-settings-sc"
        )
        let cutAtDash = SubagentNaming.slug(String(repeating: "a", count: 31) + " b")
        XCTAssertEqual(cutAtDash, String(repeating: "a", count: 31))
    }

    func testBranch() {
        XCTAssertEqual(
            SubagentNaming.branch(category: .bug, id: 7, title: "Crash on empty folder"),
            "cch/bug/7-crash-on-empty-folder"
        )
    }

    func testWorktreePathIsNamespacedByRepoHash() {
        let path = SubagentNaming.worktreePath(
            worktreesRoot: "/wt", repoRoot: "/Users/x/Code/milegacy", id: 7, title: "Dark mode"
        )
        // SHA-1("/Users/x/Code/milegacy") starts with 59d39a64
        XCTAssertEqual(path, "/wt/milegacy-59d39a64/7-dark-mode")

        let sameNameElsewhere = SubagentNaming.worktreePath(
            worktreesRoot: "/wt", repoRoot: "/Users/x/Other/milegacy", id: 7, title: "Dark mode"
        )
        XCTAssertNotEqual(path, sameNameElsewhere)
    }

    func testWorkingDirectoryKeepsSessionSubfolder() {
        XCTAssertEqual(
            SubagentNaming.workingDirectory(worktreePath: "/wt/r/7-x", sessionDir: "/repo", repoRoot: "/repo"),
            "/wt/r/7-x"
        )
        XCTAssertEqual(
            SubagentNaming.workingDirectory(worktreePath: "/wt/r/7-x", sessionDir: "/repo/app/ios", repoRoot: "/repo"),
            "/wt/r/7-x/app/ios"
        )
    }

    func testWorkingDirectoryIgnoresLookalikePrefixAndOutsideDirs() {
        XCTAssertEqual(
            SubagentNaming.workingDirectory(worktreePath: "/wt/r/7-x", sessionDir: "/repo2/app", repoRoot: "/repo"),
            "/wt/r/7-x"
        )
        XCTAssertEqual(
            SubagentNaming.workingDirectory(worktreePath: "/wt/r/7-x", sessionDir: "/elsewhere", repoRoot: "/repo"),
            "/wt/r/7-x"
        )
    }
}
