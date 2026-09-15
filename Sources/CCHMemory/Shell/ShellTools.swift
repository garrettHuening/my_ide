import Foundation

/// Escape hatch for the Claude Code Bash sandbox: when a command fails only because the sandbox
/// blocks network or filesystem access it legitimately needs, this runs it OUTSIDE the sandbox in
/// a shell script the MCP server writes. Every run is logged to the Hub console (domain `shell`),
/// so it is auditable rather than silent. Claude decides when to use it (the PostToolUse hook only
/// advises); it is not an automatic bypass of every failed command.
public enum ShellTools {
    public static let toolName = "run_outside_sandbox"
    public static let defaultTimeout: TimeInterval = 5 * 60
    public static let maxOutput = 60_000

    /// Substrings that mark a failure as a sandbox denial rather than a real error.
    public static let sandboxSignatures = [
        "operation not permitted",
        "sandbox",
        "deny(1)",
        "network-outbound",
        "sandbox-exec",
        "blocked by the sandbox",
        "seatbelt"
    ]

    public static func detectSandboxDenial(in text: String) -> String? {
        let lower = text.lowercased()
        return sandboxSignatures.first { lower.contains($0) }
    }

    public static var definition: [String: Any] {
        [
            "name": toolName,
            "description": "Run a shell command OUTSIDE the Bash sandbox, for commands that fail only because the sandbox blocks network or filesystem access they legitimately need (e.g. package installs, git push, reaching a local service). The command is written to a shell script and run with your normal permissions; the run is logged to the Hub console. Use only when a normal Bash command failed with a sandbox/permission denial and the command is safe and expected.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "command": ["type": "string", "description": "The shell command(s) to run. Runs under /bin/zsh in the given directory."],
                    "reason": ["type": "string", "description": "Why this needs to run outside the sandbox (e.g. 'npm install needs network')."],
                    "cwd": ["type": "string", "description": "Working directory. Defaults to the session directory."],
                    "timeout_seconds": ["type": "integer", "minimum": 1, "maximum": 1800]
                ],
                "required": ["command", "reason"]
            ]
        ]
    }

    public struct Result {
        public let text: String
        public let scriptPath: String
    }

    public static func run(command: String, reason: String, cwd: String, timeout: TimeInterval, console: ConsoleLog?, source: String) -> Result {
        let dir = MemoryPaths.supportDirectory + "/shell"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let scriptPath = "\(dir)/\(stamp)-\(abs(command.hashValue % 100000)).sh"
        let script = "#!/bin/zsh\n# Claude Code Hub — run outside sandbox\n# reason: \(reason.replacingOccurrences(of: "\n", with: " "))\nset -o pipefail\ncd \(shellQuote(cwd)) 2>/dev/null || true\n\n\(command)\n"
        try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)

        try? console?.append(domain: "shell", severity: .info, source: source,
                             message: "Ran outside sandbox: \(oneLine(command))",
                             dataJSON: json(["reason": reason, "cwd": cwd, "script": scriptPath, "command": command]))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptPath]
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory())
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out

        do {
            try process.run()
        } catch {
            return Result(text: "Failed to start the command: \(error)", scriptPath: scriptPath)
        }

        var timedOut = false
        let timer = DispatchWorkItem {
            if process.isRunning { timedOut = true; process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()

        var output = String(data: data, encoding: .utf8) ?? ""
        if output.count > maxOutput { output = String(output.prefix(maxOutput)) + "\n…(truncated)" }
        let status = timedOut ? "timed out after \(Int(timeout))s" : "exit \(process.terminationStatus)"
        let header = "[ran outside sandbox · \(status) · script \(scriptPath)]"
        return Result(text: output.isEmpty ? header : "\(header)\n\(output)", scriptPath: scriptPath)
    }

    /// PostToolUse(Bash): if the command failed with a sandbox signature, advise Claude it can retry
    /// outside the sandbox. Returns the additionalContext JSON, or "" when nothing to say.
    public static func postToolUseHook(payload: [String: Any], toolPrefix: String, console: ConsoleLog?) -> String {
        guard (payload["tool_name"] as? String) == "Bash" else { return "" }
        let response = payload["tool_response"]
        let text = flatten(response) + " " + flatten(payload["tool_input"])
        guard let signature = detectSandboxDenial(in: text) else { return "" }
        // Only nudge on an actual failure, not a warning in successful output.
        let failed = (asDict(response)?["is_error"] as? Bool == true)
            || (asDict(response)?["interrupted"] as? Bool == true)
            || flatten(response).lowercased().contains("error")
            || flatten(response).lowercased().contains(signature)
        guard failed else { return "" }
        let command = (asDict(payload["tool_input"])?["command"] as? String) ?? ""
        try? console?.append(domain: "shell", severity: .info, source: "hook:PostToolUse",
                             message: "Bash hit a sandbox denial (\(signature))", dataJSON: json(["command": command]))
        let context = "That Bash command appears to have been blocked by the sandbox (matched \"\(signature)\"). If the command is safe and needs network or filesystem access the sandbox forbids, retry it with the \(toolPrefix)\(toolName) tool, giving a short reason. Otherwise treat it as a genuine failure."
        return json(["hookSpecificOutput": ["hookEventName": "PostToolUse", "additionalContext": context]])
    }

    // MARK: Helpers

    private static func asDict(_ value: Any?) -> [String: Any]? { value as? [String: Any] }

    private static func flatten(_ value: Any?) -> String {
        switch value {
        case let s as String: return s
        case let d as [String: Any]:
            return d.values.map { flatten($0) }.joined(separator: " ")
        case let a as [Any]:
            return a.map { flatten($0) }.joined(separator: " ")
        default: return ""
        }
    }

    private static func oneLine(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 160 ? String(flat.prefix(159)) + "…" : flat
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func json(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
