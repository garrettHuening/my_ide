import CCHMemory
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
    StdioServer(store: openStore(), console: console, directory: directory, source: "claude:\(role)").run()

case "hook":
    let event = arguments.dropFirst().first ?? ""
    let payload = readStdinJSON()
    let store = openStore()
    // A hook must never hold up the prompt: give up after 1.5 s and print nothing.
    var output = ""
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        switch event {
        case "user-prompt-submit": output = HookHandlers.userPromptSubmit(payload: payload, store: store, console: console)
        case "stop": output = HookHandlers.stop(payload: payload, store: store, console: console)
        default: break
        }
        done.signal()
    }
    if done.wait(timeout: .now() + 1.5) == .timedOut {
        try? console?.append(domain: "memory", severity: .warning, source: "hook:\(event)",
                             message: "hook timed out after 1.5s; nothing injected", sessionID: payload["session_id"] as? String)
        exit(0)
    }
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

default:
    fail("usage: cch-mcp serve | hook user-prompt-submit|stop | log --domain D --severity S message")
}
