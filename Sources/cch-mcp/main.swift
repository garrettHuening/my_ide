import CCHMemory
import CCHSubagents
import Foundation

// cch-mcp — Claude Code Hub's bridge into core memory.
//   cch-mcp serve                       stdio MCP server (memory, bug and log tools)
//   cch-mcp hook user-prompt-submit     retrieval: prints additionalContext JSON
//   cch-mcp hook stop                   strict-grounding check
//   cch-mcp log --domain D --severity S [--source X] [--data JSON] message…   open logging API

let arguments = Array(CommandLine.arguments.dropFirst())
let environment = ProcessInfo.processInfo.environment

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("cch-mcp: \(message)\n".utf8))
    exit(1)
}

func readStdinJSON() -> [String: Any] {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

func openStore() -> MemoryStore {
    do {
        return try MemoryStore()
    } catch {
        fail("cannot open memory database: \(error)")
    }
}

let console = try? ConsoleLog()

switch arguments.first {
case "serve":
    let directory = environment["CCH_SESSION_DIR"] ?? FileManager.default.currentDirectoryPath
    let role = environment["CCH_ROLE"] ?? "external"
    let toolset = environment["CCH_TOOLSET"].flatMap(Toolset.init(rawValue:)) ?? .main
    StdioServer(store: openStore(), console: console, directory: directory, source: "claude:\(role)", toolset: toolset).run()

case "hook" where arguments.dropFirst().first == "session-snapshot":
    // PreCompact / SessionEnd: hand off to a detached summarizer and return at once.
    let payload = readStdinJSON()
    guard let session = payload["session_id"] as? String, let transcript = payload["transcript_path"] as? String else { exit(0) }
    let cwd = payload["cwd"] as? String ?? FileManager.default.currentDirectoryPath
    let event = payload["hook_event_name"] as? String ?? "unknown"
    if !Detached.spawn(executable: Detached.selfPath,
                       arguments: ["snapshot", "--session", session, "--transcript", transcript, "--cwd", cwd, "--event", event]) {
        try? console?.append(domain: "session", severity: .error, source: "hook:\(event)", message: "could not start session summarizer", sessionID: session)
    }
    exit(0)

case "snapshot":
    let flags = Flags(Array(arguments.dropFirst()))
    guard let session = flags["--session"], let transcript = flags["--transcript"], let cwd = flags["--cwd"] else {
        fail("usage: cch-mcp snapshot --session ID --transcript PATH --cwd DIR [--event NAME]")
    }
    SessionSummarizer(store: openStore(), console: console).run(sessionID: session, transcriptPath: transcript,
                                                                cwd: cwd, event: flags["--event"] ?? "manual")

case "hook":
    let event = arguments.dropFirst().first ?? ""
    let payload = readStdinJSON()
    let toolPrefix = environment["CCH_TOOL_PREFIX"] ?? MemoryTools.toolPrefix
    // A hook must never hold up the prompt: memory work gets 1.5 s, the subagent service 3 s.
    var memoryOutput = ""
    if event == "user-prompt-submit" || event == "stop" {
        let store = openStore()
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = event == "stop"
                ? HookHandlers.stop(payload: payload, store: store, console: console)
                : HookHandlers.userPromptSubmit(payload: payload, store: store, console: console, toolPrefix: toolPrefix)
            lock.lock()
            memoryOutput = result
            lock.unlock()
            done.signal()
        }
        if done.wait(timeout: .now() + 1.5) == .timedOut {
            try? console?.append(domain: "memory", severity: .warning, source: "hook:\(event)",
                                 message: "memory hook timed out after 1.5s; nothing injected", sessionID: payload["session_id"] as? String)
        }
    }
    var agentdOutput = ""
    if let agentID = environment["CCH_AGENT_ID"].flatMap(Int.init),
       case .success(let result) = AgentdConnection().call("hook", ["event": event, "payload": payload, "agentID": agentID], timeout: 3),
       let text = (result as? [String: Any])?["stdout"] as? String {
        agentdOutput = text
    }
    let output = agentdOutput.isEmpty ? memoryOutput : agentdOutput
    if !output.isEmpty { print(output) }
    exit(0)

case "log":
    guard let console else { fail("cannot open console database") }
    var domain: String?
    var severity = LogSeverity.info
    var source = "cli"
    var data: String?
    var words: [String] = []
    var index = 1
    while index < arguments.count {
        let arg = arguments[index]
        func value() -> String {
            index += 1
            guard index < arguments.count else { fail("\(arg) needs a value") }
            return arguments[index]
        }
        switch arg {
        case "--domain": domain = value()
        case "--severity":
            let raw = value()
            guard let s = LogSeverity(rawValue: raw) else { fail("severity must be debug, info, warning or error") }
            severity = s
        case "--source": source = value()
        case "--data": data = value()
        default: words.append(arg)
        }
        index += 1
    }
    guard let domain else { fail("--domain is required") }
    guard !words.isEmpty else { fail("a message is required") }
    do {
        try console.append(domain: domain, severity: severity, source: source, message: words.joined(separator: " "), dataJSON: data)
    } catch {
        fail("\(error)")
    }

case "agentd":
    // Dev/troubleshooting: cch-mcp agentd register | unregister | status | call METHOD [JSON]
    let service = SMAppServiceBridge()
    switch arguments.dropFirst().first {
    case "register": print(service.register())
    case "unregister": print(service.unregister())
    case "status": print(service.status())
    case "call":
        let method = arguments.dropFirst(2).first ?? "ping"
        let params = arguments.dropFirst(3).first.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
        switch AgentdConnection().call(method, params, timeout: 120) {
        case .success(let result):
            let data = (try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])) ?? Data()
            print(String(data: data, encoding: .utf8) ?? "\(result)")
        case .failure(let error):
            fail(error.message)
        }
    default:
        fail("usage: cch-mcp agentd register|unregister|status|call METHOD [JSON]")
    }

case "sweep-prompt":
    // Debug: print the repo-sweep prompt the Hub sends (full sweep).
    print(SweepPrompt.text(mode: .full, changedFiles: []))

case "dream-prompt":
    // Debug: print the dreaming prompt. cch-mcp dream-prompt <project name> <candidate count>
    print(Dreaming.prompt(projectName: arguments.dropFirst().first ?? "project", candidateCount: Int(arguments.dropFirst(2).first ?? "") ?? 0))

default:
    fail("usage: cch-mcp serve | hook user-prompt-submit|stop | log --domain D --severity S message | sweep-prompt")
}
