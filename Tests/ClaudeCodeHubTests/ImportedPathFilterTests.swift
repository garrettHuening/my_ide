import XCTest
@testable import ClaudeCodeHub

/// BUG-1: the sidebar imported macOS temp locations as sessions.
final class ImportedPathFilterTests: XCTestCase {
    private let home = "/Users/tester"
    private let tmpdir = "/var/folders/qg/6ngdy_6d4xz2x_t0ls8t89bh0000gn/T/"

    private func env() -> ImportedPathFilter.Environment {
        ImportedPathFilter.Environment(home: home, temporaryDirectory: tmpdir)
    }

    private func reason(_ path: String) -> ImportSkipReason? {
        ImportedPathFilter.skipReason(for: path, env: env())
    }

    private func assertSkipped(_ path: String,
                               _ expected: ImportSkipReason,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        XCTAssertEqual(reason(path), expected, "expected to skip \(path)", file: file, line: line)
    }

    private func assertKept(_ path: String,
                            file: StaticString = #filePath,
                            line: UInt = #line) {
        XCTAssertNil(reason(path), "expected to keep \(path)", file: file, line: line)
    }

    // MARK: - The reported path

    /// The exact path the user reported, as Claude Code would encode and the
    /// importer would decode it.
    func testReportedScreenshotPathIsSkipped() {
        assertSkipped(
            "/var/folders/qg/6ngdy_6d4xz2x_t0ls8t89bh0000gn/T/TemporaryItems/NSIRD_screencaptureui_7Zmosg/Screenshot 2026-09-21 at 1.33.57 PM.png",
            .temporary
        )
    }

    /// macOS resolves /var through the /private symlink, so Claude Code's own
    /// encoding often carries the /private spelling. Both must skip alike.
    func testPrivateTwinOfReportedPathIsSkipped() {
        assertSkipped(
            "/private/var/folders/qg/6ngdy_6d4xz2x_t0ls8t89bh0000gn/T/TemporaryItems/NSIRD_screencaptureui_7Zmosg/Screenshot 2026-09-21 at 1.33.57 PM.png",
            .temporary
        )
    }

    // MARK: - Transient locations

    func testTemporaryLocationsAreSkipped() {
        assertSkipped("\(tmpdir)some-scratch-repo", .temporary)               // $TMPDIR child
        assertSkipped("/var/folders/qg/abc/T", .temporary)
        assertSkipped("/var/folders", .temporary)
        assertSkipped("/tmp/foo", .temporary)
        assertSkipped("/tmp", .temporary)
        assertSkipped("/private/tmp", .temporary)
        assertSkipped("/private/tmp/cch-paste-probe-1789436040", .temporary)
        assertSkipped("/var/tmp/build-cache", .temporary)
        assertSkipped("/private/var/tmp/build-cache", .temporary)
    }

    /// These really were imported into the user's sidebar (app.db rows 13/14/21/30).
    func testScratchpadDirectoriesAreSkipped() {
        assertSkipped(
            "/private/tmp/claude-501/-Users-tester-Documents-Claude-CCH/b11c71d6/scratchpad/shellwork",
            .temporary
        )
    }

    /// macOS parks screenshots and drag payloads in these, wherever they sit.
    func testTemporaryItemsAndNSIRDAnywhereAreSkipped() {
        assertSkipped("\(home)/Downloads/TemporaryItems/thing", .temporary)
        assertSkipped("\(home)/Downloads/NSIRD_screencaptureui_ABC123/shot.png", .temporary)
    }

    // MARK: - Exact skips carried over from the original rule

    func testHomeAndRootAreSkipped() {
        assertSkipped(home, .home)
        assertSkipped("\(home)/", .home)
        assertSkipped("/", .root)
        assertSkipped("/var", .systemDirectory)
        assertSkipped("/private/var", .systemDirectory)
    }

    // MARK: - Real projects must survive

    func testOrdinaryProjectsAreKept() {
        assertKept("\(home)/Documents/Claude/CCH")
        assertKept("\(home)/Documents/Claude/CCH/ClaudeCodeHub")
        assertKept("\(home)/.cch/worktrees/ClaudeCodeHub-d907bbbe/7-filter-temp-dirs")
        assertKept("\(home)/Library/Application Support/ClaudeCodeHub/worktrees/e2e/2-fix-add-function")
        assertKept("\(home)/Documents/Yellowstone Vacation")
    }

    /// Unusual but legitimate homes for a checkout. Blanket-skipping these
    /// top-level directories would lose real projects.
    func testUnusualButRealProjectLocationsAreKept() {
        assertKept("/var/www/mysite")            // classic web root, under /var
        assertKept("/opt/homebrew/src/formula")
        assertKept("/usr/local/src/project")
        assertKept("/Library/WebServer/Documents/site")
        assertKept("/Volumes/Data/code/project")
        // On APFS every user file is also reachable through this firmlink, so
        // skipping all of /System would throw away real project paths.
        assertKept("/System/Volumes/Data\(home)/Documents/Claude/CCH")
    }

    // MARK: - Canonicalisation

    func testCanonicalCollapsesPrivateAliasAndTrailingSlash() {
        XCTAssertEqual(ImportedPathFilter.canonical("/private/tmp/foo/"), "/tmp/foo")
        XCTAssertEqual(ImportedPathFilter.canonical("/private/var/folders"), "/var/folders")
        XCTAssertEqual(ImportedPathFilter.canonical("/"), "/")
        // Not an alias: a real directory that merely starts with "private".
        XCTAssertEqual(ImportedPathFilter.canonical("/privateers/var"), "/privateers/var")
        XCTAssertEqual(ImportedPathFilter.canonical("/private/etc/hosts"), "/etc/hosts")
    }

    /// $TMPDIR is absent in some launch contexts; the built-in prefixes still apply.
    func testWorksWithoutTMPDIR() {
        let bare = ImportedPathFilter.Environment(home: home, temporaryDirectory: nil)
        XCTAssertEqual(
            ImportedPathFilter.skipReason(for: "/var/folders/qg/abc/T/TemporaryItems/x", env: bare),
            .temporary
        )
        XCTAssertNil(ImportedPathFilter.skipReason(for: "\(home)/Documents/CCH", env: bare))
    }
}
