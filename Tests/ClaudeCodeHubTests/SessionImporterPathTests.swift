import XCTest
@testable import ClaudeCodeHub

/// BUG-1, end to end over the real filesystem: a Claude-encoded state-dir name
/// that points into a macOS temp location must be rejected, whatever
/// `decodeProjectName` manages to make of it.
final class SessionImporterPathTests: XCTestCase {
    private var scratch: URL?

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    /// Mirror Claude Code's own project-folder encoding: leading "-", then every
    /// non-alphanumeric character replaced by "-".
    private func claudeEncode(_ path: String) -> String {
        "-" + String(path.dropFirst().map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    private func makeScratchDir(_ name: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scratch = dir
        return dir
    }

    /// The reported case. macOS refuses to list `TemporaryItems` (EPERM, even
    /// unsandboxed), so `decodeProjectName` cannot walk into it and falls back to
    /// splitting on "-", yielding a path that does not exist. That is precisely
    /// why the leaf-is-a-file check cannot be the defence: only the path rule
    /// catches this one.
    func testEncodedScreenshotTempPathIsSkippedEvenWhenDecodeDegrades() throws {
        let real = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("TemporaryItems/NSIRD_screencaptureui_7Zmosg/Screenshot 2026-09-21 at 1.33.57 PM.png")

        let decoded = SessionImporter.decodeProjectName(claudeEncode(real.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: decoded),
                       "decode is expected to degrade here; if this ever round-trips, revisit the comment above")
        XCTAssertEqual(ImportedPathFilter.skipReason(for: decoded), .temporary)
        XCTAssertEqual(ImportedPathFilter.skipReason(for: real.path), .temporary)
    }

    /// A readable temp directory: decode round-trips exactly, and the filter
    /// still rejects it. This is the shape of the rows already sitting in the
    /// user's sidebar (`/private/tmp/...`).
    func testEncodedReadableTempDirectoryDecodesAndIsSkipped() throws {
        let dir = try makeScratchDir("cch-bug1-scratch")

        let decoded = SessionImporter.decodeProjectName(claudeEncode(dir.path))
        XCTAssertEqual(decoded, dir.path)
        XCTAssertEqual(ImportedPathFilter.skipReason(for: decoded), .temporary)
        XCTAssertFalse(SessionImporter.isExistingFile(decoded))
    }

    /// The second guard, isolated: a decoded path that lands on a plain file is
    /// rejected even when it sits in a perfectly ordinary location.
    func testDecodedPathLandingOnAFileIsRejected() throws {
        let manifest = Self.packageRoot.appendingPathComponent("Package.swift")
        let decoded = SessionImporter.decodeProjectName(claudeEncode(manifest.path))

        XCTAssertEqual(decoded, manifest.path)
        XCTAssertNil(ImportedPathFilter.skipReason(for: decoded), "nothing transient about this path")
        XCTAssertTrue(SessionImporter.isExistingFile(decoded), "but it is a file, so the importer drops it")
    }

    /// A perfectly ordinary project still decodes and still imports.
    func testOrdinaryProjectDirectorySurvives() throws {
        let repo = Self.packageRoot
        let decoded = SessionImporter.decodeProjectName(claudeEncode(repo.path))

        XCTAssertEqual(decoded, repo.path)
        XCTAssertNil(ImportedPathFilter.skipReason(for: decoded))
        XCTAssertFalse(SessionImporter.isExistingFile(decoded))
    }

    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ClaudeCodeHubTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
    }
}
