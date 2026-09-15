import XCTest
@testable import CCHMemory

final class ShellToolsTests: XCTestCase {
    private var tempDir: URL!
    private var console: ConsoleLog!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("cch-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        setenv("CCH_SUPPORT_DIR", tempDir.path, 1)
        console = try ConsoleLog(path: tempDir.appendingPathComponent("console.db").path)
    }

    override func tearDownWithError() throws {
        unsetenv("CCH_SUPPORT_DIR")
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDetectsSandboxSignatures() {
        XCTAssertEqual(ShellTools.detectSandboxDenial(in: "curl: (7) Operation not permitted"), "operation not permitted")
        XCTAssertNotNil(ShellTools.detectSandboxDenial(in: "sandbox-exec: execvp() denied"))
        XCTAssertNotNil(ShellTools.detectSandboxDenial(in: "deny(1) network-outbound"))
        XCTAssertNil(ShellTools.detectSandboxDenial(in: "fatal: not a git repository"))
    }

    func testRunExecutesAndLogs() {
        let result = ShellTools.run(command: "echo hello-sandbox && echo err >&2", reason: "test",
                                    cwd: tempDir.path, timeout: 30, console: console, source: "test")
        XCTAssertTrue(result.text.contains("hello-sandbox"))
        XCTAssertTrue(result.text.contains("ran outside sandbox · exit 0"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.scriptPath))
        XCTAssertEqual((try? console.recent(domains: ["shell"]))?.count, 1)
    }

    func testRunReportsNonZeroExit() {
        let result = ShellTools.run(command: "exit 3", reason: "test", cwd: tempDir.path, timeout: 30, console: console, source: "test")
        XCTAssertTrue(result.text.contains("exit 3"))
    }

    func testRunTimesOut() {
        let result = ShellTools.run(command: "sleep 5", reason: "test", cwd: tempDir.path, timeout: 1, console: console, source: "test")
        XCTAssertTrue(result.text.contains("timed out"))
    }

    func testPostToolUseHookAdvisesOnFailure() throws {
        let payload: [String: Any] = [
            "tool_name": "Bash",
            "tool_input": ["command": "npm install"],
            "tool_response": ["is_error": true, "stderr": "npm error network Operation not permitted"]
        ]
        let out = ShellTools.postToolUseHook(payload: payload, toolPrefix: "mcp__x__", console: console)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        let specific = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        let context = try XCTUnwrap(specific["additionalContext"] as? String)
        XCTAssertTrue(context.contains("mcp__x__run_outside_sandbox"))
        XCTAssertTrue(context.contains("operation not permitted"))
    }

    func testPostToolUseHookIgnoresNonBashAndCleanRuns() {
        XCTAssertEqual(ShellTools.postToolUseHook(payload: ["tool_name": "Read"], toolPrefix: "p_", console: console), "")
        let clean: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": "ls"], "tool_response": ["stdout": "file.txt"]]
        XCTAssertEqual(ShellTools.postToolUseHook(payload: clean, toolPrefix: "p_", console: console), "")
    }

    func testDefinitionIsValidJSON() {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(ShellTools.definition))
        XCTAssertEqual(ShellTools.definition["name"] as? String, "run_outside_sandbox")
    }
}
