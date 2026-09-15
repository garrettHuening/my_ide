import XCTest
@testable import CCHMemory

final class ProjectKeyTests: MemoryTestCase {
    func testRemoteNormalization() {
        XCTAssertEqual(ProjectKey.normalizeRemote("git@github.com:Me/App.git"), "github.com/me/app")
        XCTAssertEqual(ProjectKey.normalizeRemote("https://me@github.com/me/app"), "github.com/me/app")
        XCTAssertEqual(ProjectKey.normalizeRemote("https://github.com/me/app.git/"), "github.com/me/app")
        XCTAssertEqual(ProjectKey.normalizeRemote("ssh://git@github.com:22/me/app.git"), "github.com/me/app")
        XCTAssertNil(ProjectKey.normalizeRemote("/Users/me/bare.git"))
        XCTAssertNil(ProjectKey.normalizeRemote(""))
    }

    func testWorktreesShareTheMainCheckoutKey() throws {
        let repo = tempDir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: repo)
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        let worktree = tempDir.appendingPathComponent("wt")
        try git(["worktree", "add", "-q", "-b", "feature", worktree.path], in: repo)

        let main = ProjectKey.resolve(directory: repo.path)
        let wt = ProjectKey.resolve(directory: worktree.path)
        XCTAssertEqual(main.key, wt.key)
        XCTAssertEqual(wt.name, "repo")
        XCTAssertEqual(wt.branch, "feature")

        try git(["remote", "add", "origin", "git@github.com:me/repo.git"], in: repo)
        XCTAssertEqual(ProjectKey.resolve(directory: worktree.path).key, "github.com/me/repo")
    }

    func testNonGitFolderIsItsOwnProject() {
        let resolved = ProjectKey.resolve(directory: tempDir.path)
        XCTAssertEqual(resolved.key, tempDir.resolvingSymlinksInPath().path)
        XCTAssertNil(resolved.branch)
    }
}

final class QueryTests: XCTestCase {
    func testTokensDropStopwordsShortWordsAndDuplicates() {
        XCTAssertEqual(FTSQuery.tokens(in: "Why do I see the SAME session twice? session_store!"),
                       ["see", "same", "session", "twice", "session_store"])
    }

    func testMatchQuotesTokensAndSurvivesFTSSyntax() {
        XCTAssertEqual(FTSQuery.match(for: "deploy AND \"prod\" NEAR(x)"), "\"deploy\" OR \"prod\" OR \"near\"")
        XCTAssertNil(FTSQuery.match(for: "is it ok?"))
    }

    func testReciprocalRankFusionRewardsAgreement() {
        let scores = Retriever.reciprocalRankFusion([[1, 2, 3], [2, 1, 4]], k: 60)
        XCTAssertEqual(scores[1]!, scores[2]!, accuracy: 1e-12)
        XCTAssertGreaterThan(scores[2]!, scores[3]!)
        XCTAssertGreaterThan(scores[3]!, 0)
        XCTAssertEqual(scores[4]!, 1.0 / 63.0, accuracy: 1e-12)
    }
}
