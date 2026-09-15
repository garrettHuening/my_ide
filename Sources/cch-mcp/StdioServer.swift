import CCHMemory
import Foundation

/// Newline-delimited JSON-RPC 2.0 over stdio, the MCP stdio transport.
final class StdioServer {
    private let store: MemoryStore
    private let console: ConsoleLog?
    private let directory: String
    private let source: String
    private lazy var resolved = ProjectKey.resolve(directory: directory)

    init(store: MemoryStore, console: ConsoleLog?, directory: String, source: String) {
        self.store = store
        self.console = console
        self.directory = directory
        self.source = source
    }

    func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        let id = message["id"]
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let version = params["protocolVersion"] as? String ?? "2025-06-18"
            reply(id, result: [
                "protocolVersion": version,
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "cch", "version": "0.1.0"],
                "instructions": "Claude Code Hub core memory: search and record durable project knowledge, track bugs in an append-only ledger, and log to the Hub console."
            ])
        case "ping":
            reply(id, result: [:])
        case "tools/list":
            reply(id, result: ["tools": MemoryTools.definitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let project = try store.project(for: resolved)
                let context = ToolContext(store: store, console: console, project: project, branch: resolved.branch,
                                          sessionID: nil, source: source)
                let text = try MemoryTools.call(name, arguments: args, context: context)
                reply(id, result: ["content": [["type": "text", "text": text]]])
            } catch {
                reply(id, result: ["content": [["type": "text", "text": "Error: \(error)"]], "isError": true])
            }
        default:
            if id != nil {
                send(["jsonrpc": "2.0", "id": id as Any, "error": ["code": -32601, "message": "Method not found: \(method)"]])
            }
        }
    }

    private func reply(_ id: Any?, result: [String: Any]) {
        guard let id else { return }
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
