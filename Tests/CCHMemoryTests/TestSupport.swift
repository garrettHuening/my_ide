import Foundation
import XCTest
@testable import CCHMemory

class MemoryTestCase: XCTestCase {
    var tempDir: URL!
    var store: MemoryStore!
    var console: ConsoleLog!
    var project: Project!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("cch-mem-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try MemoryStore(path: tempDir.appendingPathComponent("memory.db").path, embedder: HashingEmbedder())
        console = try ConsoleLog(path: tempDir.appendingPathComponent("console.db").path)
        project = try store.project(for: ResolvedProject(key: "github.com/me/app", name: "app", root: "/src/app", branch: "main"))
    }

    override func tearDownWithError() throws {
        store = nil
        console = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    @discardableResult
    func write(_ kind: MemoryKind, _ title: String, _ body: String, source: MemorySource = .code,
               links: [(to: Int64, relation: EdgeRelation)] = [], projectID: Int64? = nil) throws -> Memory {
        try store.writeMemory(projectID: projectID ?? project.id, kind: kind, title: title, body: body, source: source, links: links).memory
    }

    func context(sessionID: String? = "s1") -> ToolContext {
        ToolContext(store: store, console: console, project: project, branch: "main", sessionID: sessionID, source: "test")
    }

    func git(_ args: [String], in dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "git \(args.joined(separator: " "))")
    }
}
