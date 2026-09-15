import CCHMemory
import CCHSubagents
import Darwin
import Foundation

/// All subagent state lives here and is touched only on `queue`.
final class Supervisor {
    let queue = DispatchQueue(label: "cch.agentd")
    let db: AgentsDB
    let git = Git()
    let console = try? ConsoleLog()

    /// App connections (receive snapshots, output, merge deliveries).
    var appPeers: [ObjectIdentifier: NSXPCConnection] = [:]
    /// Host connection per subagent.
    var hosts: [Int64: NSXPCConnection] = [:]
    var buffers: [Int64: Data] = [:]
    var terminalSizes: [Int64: (cols: Int, rows: Int)] = [:]
    /// Subagents whose next host launch resumes the conversation instead of starting it.
    var resumeOnLaunch: Set<Int64> = []
    /// Text to type into a subagent once its host is up.
    var pendingMessages: [Int64: [String]] = [:]
    /// Increments cancel pending commit-wait timeouts.
    var commitWaitGeneration: [Int64: Int] = [:]
    /// Login-shell PATH so subagents find the same tools the user's terminal does.
    lazy var userPath: String = Supervisor.loginShellPath()

    /// Worktrees live outside repositories in a path without spaces: Claude Code asks for extra
    /// confirmation on shell commands whose paths contain escaped whitespace ("Application Support").
    static var worktreesRoot: String {
        ProcessInfo.processInfo.environment["CCH_WORKTREES_DIR"] ?? NSHomeDirectory() + "/.cch/worktrees"
    }

    static let bufferLimit = 2 * 1024 * 1024
    static let logLimit: UInt64 = 20 * 1024 * 1024
    static let commitWaitTimeout: TimeInterval = 10 * 60
    static let messageDelayAfterLaunch: TimeInterval = 8

    init() throws {
        db = try AgentsDB()
    }

    // MARK: Dispatch

    func handle(method: String, params: [String: Any], from connection: NSXPCConnection, reply: @escaping (Data) -> Void) {
        queue.async {
            do {
                let result = try self.dispatch(method: method, params: params, connection: connection)
                reply(RPC.ok(result))
            } catch {
                reply(RPC.failure("\(error)"))
            }
        }
    }

    private func dispatch(method: String, params p: [String: Any], connection: NSXPCConnection) throws -> Any {
        switch method {
        case "ping": return ["pid": Int(getpid())]

        // App
        case "app.subscribe":
            appPeers[ObjectIdentifier(connection)] = connection
            return SubagentSnapshot.encode(try snapshots(sessionID: nil))
        case "app.attach":
            let agent = try id(p)
            return ["data": (buffers[agent] ?? logTail(agent)).base64EncodedString()]
        case "app.input":
            let agent = try id(p)
            if let data = (p["data"] as? String).flatMap({ Data(base64Encoded: $0) }) { sendToHost(agent, "input", ["data": data.base64EncodedString()]) }
            return [:]
        case "app.resize":
            let agent = try id(p)
            let size = (cols: max(p["cols"] as? Int ?? 120, 20), rows: max(p["rows"] as? Int ?? 40, 5))
            terminalSizes[agent] = size
            sendToHost(agent, "resize", ["cols": size.cols, "rows": size.rows])
            return [:]
        case "app.merge": return try requestMerge(try id(p))
        case "app.stop": try stop(try id(p)); return [:]
        case "app.reopen": try reopen(try id(p), nudge: false); return [:]
        case "app.resume": try reopen(try id(p), nudge: true); return [:]
        case "app.discard": try discard(try id(p)); return [:]
        case "app.removeFromGroup": try removeFromGroup(try id(p)); return [:]
        case "app.clearDone":
            try db.hideArchived(sessionID: Int64(p["sessionID"] as? Int ?? 0))
            pushSnapshots()
            return [:]
        case "app.settings.get": return try settings()
        case "app.settings.set": try setSettings(p); return try settings()

        // cch-mcp
        case "tool": return ["text": try tool(name: p["name"] as? String ?? "", args: p["args"] as? [String: Any] ?? [:],
                                              caller: p["caller"] as? [String: Any] ?? [:])]
        case "hook": return ["stdout": hook(event: p["event"] as? String ?? "", payload: p["payload"] as? [String: Any] ?? [:],
                                             agentID: (p["agentID"] as? Int).map(Int64.init))]

        // Hosts
        case "host.hello": return try hostHello(try id(p), pid: Int32(p["pid"] as? Int ?? 0), connection: connection, reattach: false)
        case "host.reattach": return try hostHello(try id(p), pid: Int32(p["pid"] as? Int ?? 0), connection: connection, reattach: true)
        case "host.exited": try hostExited(try id(p), code: Int32(p["code"] as? Int ?? -1)); return [:]
        case "host.trustPrompt": try trustPrompt(try id(p), handled: p["handled"] as? Bool ?? false); return [:]

        default: throw RPCError(message: "unknown method \(method)")
        }
    }

    func id(_ p: [String: Any]) throws -> Int64 {
        if let i = p["id"] as? Int { return Int64(i) }
        if let i = p["id"] as? Int64 { return i }
        throw RPCError(message: "missing id")
    }

    func require(_ id: Int64) throws -> Subagent {
        guard let s = try db.subagent(id: id) else { throw RPCError(message: "subagent #\(id) not found") }
        return s
    }

    // MARK: Connections

    func connectionClosed(_ connection: NSXPCConnection) {
        queue.async {
            self.appPeers.removeValue(forKey: ObjectIdentifier(connection))
            for (agent, host) in self.hosts where host === connection {
                self.hosts.removeValue(forKey: agent)
                // A host that vanishes without host.exited crashed; recovery decides what to do.
                if let s = try? self.db.subagent(id: agent) {
                    self.log(.warning, "host for #\(agent) disconnected unexpectedly", subagent: s)
                    self.queue.asyncAfter(deadline: .now() + 3) {
                        guard self.hosts[agent] == nil, let current = try? self.db.subagent(id: agent) else { return }
                        self.recover(current, abnormal: true)
                    }
                }
            }
        }
    }

    func sendToHost(_ agentID: Int64, _ type: String, _ fields: [String: Any]) {
        guard let host = hosts[agentID] else { return }
        (host.remoteObjectProxyWithErrorHandler { _ in } as? PeerXPC)?.event(RPC.event(type, fields))
    }

    /// Types a message into a subagent (bracketed paste + Enter, done by the host).
    func deliver(_ agentID: Int64, _ text: String) {
        if hosts[agentID] != nil {
            sendToHost(agentID, "message", ["text": text])
        } else {
            pendingMessages[agentID, default: []].append(text)
        }
    }

    // MARK: Output

    func hostOutput(agentID: Int64, data: Data) {
        queue.async {
            var buffer = self.buffers[agentID] ?? Data()
            buffer.append(data)
            if buffer.count > Self.bufferLimit { buffer = buffer.suffix(Self.bufferLimit) }
            self.buffers[agentID] = buffer
            self.appendLog(agentID, data)
            for peer in self.appPeers.values {
                (peer.remoteObjectProxyWithErrorHandler { _ in } as? PeerXPC)?.output(agentID, data: data)
            }
        }
    }

    func subagentDirectory(_ id: Int64) -> String {
        let dir = MemoryPaths.supportDirectory + "/subagents/\(id)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func appendLog(_ id: Int64, _ data: Data) {
        let path = subagentDirectory(id) + "/pty.log"
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? UInt64, size > Self.logLimit {
            try? fm.removeItem(atPath: path + ".1")
            try? fm.moveItem(atPath: path, toPath: path + ".1")
        }
        if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }

    func logTail(_ id: Int64) -> Data {
        guard let data = FileManager.default.contents(atPath: subagentDirectory(id) + "/pty.log") else { return Data() }
        return data.suffix(Self.bufferLimit)
    }

    // MARK: Snapshots

    func snapshots(sessionID: Int64?) throws -> [SubagentSnapshot] {
        try db.subagents(sessionID: sessionID).filter { $0.state != .discarded }.map { s in
            let workingStates: Set<SubagentState> = [.idle, .complete, .merging, .interrupted, .stopped]
            let inspect = workingStates.contains(s.state) && FileManager.default.fileExists(atPath: s.worktreePath)
            let hasCommits = inspect && git.commitCount(from: s.baseCommit, to: "HEAD", in: s.worktreePath) > 0
            let isDirty = inspect && !git.dirtyFiles(s.worktreePath).isEmpty
            return SubagentSnapshot(subagent: s, groupName: try s.mergeGroupID.flatMap { try db.group(id: $0)?.name },
                                    report: try db.latestReport(subagentID: s.id), note: try db.note(s.id),
                                    hidden: try db.isHidden(s.id), hasCommits: hasCommits, isDirty: isDirty,
                                    hostAlive: hosts[s.id] != nil)
        }
    }

    func pushSnapshots() {
        guard !appPeers.isEmpty, let list = try? snapshots(sessionID: nil) else { return }
        let event = RPC.event("subagents", ["subagents": SubagentSnapshot.encode(list)])
        for peer in appPeers.values {
            (peer.remoteObjectProxyWithErrorHandler { _ in } as? PeerXPC)?.event(event)
        }
    }

    func pushToApps(_ type: String, _ fields: [String: Any]) -> Bool {
        let event = RPC.event(type, fields)
        for peer in appPeers.values {
            (peer.remoteObjectProxyWithErrorHandler { _ in } as? PeerXPC)?.event(event)
        }
        return !appPeers.isEmpty
    }

    // MARK: State transitions

    /// Applies an event through the state machine and persists. Illegal transitions are logged, not thrown.
    @discardableResult
    func transition(_ s: inout Subagent, _ event: SubagentEvent) -> Bool {
        do {
            s.phase = try SubagentStateMachine.apply(event, to: s.phase)
            try db.save(s)
            return true
        } catch {
            log(.debug, "ignored \(event) in \(s.phase): \(error)", subagent: s)
            return false
        }
    }

    // MARK: Settings

    func settings() throws -> [String: Any] {
        var models: [String: String] = [:]
        for category in SubagentCategory.allCases {
            models[category.rawValue] = try db.defaultModel(for: category) ?? ""
        }
        return ["models": models, "autoResume": try db.autoResume()]
    }

    func setSettings(_ p: [String: Any]) throws {
        if let models = p["models"] as? [String: String] {
            for (key, value) in models {
                guard let category = SubagentCategory(rawValue: key) else { continue }
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                guard trimmed.isEmpty || SubagentModel.isValid(trimmed) else {
                    throw RPCError(message: "Unknown model '\(trimmed)'. Use fable, opus, sonnet, haiku, or a full claude-… model name.")
                }
                try db.setPref(SubagentModel.prefKey(for: category), trimmed)
            }
        }
        if let autoResume = p["autoResume"] as? Bool {
            try db.setPref(AgentsDB.autoResumeKey, autoResume ? "1" : "0")
        }
    }

    // MARK: Logging

    func log(_ severity: LogSeverity, _ message: String, subagent: Subagent? = nil) {
        let prefix = subagent.map { "#\($0.id) \($0.title): " } ?? ""
        try? console?.append(domain: "subagents", severity: severity, source: "agentd", message: prefix + message)
        print("[\(severity.rawValue)] \(prefix)\(message)")
    }

    static func loginShellPath() -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "printf %s \"$PATH\""]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let fallback = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        guard (try? process.run()) != nil else { return fallback }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? fallback : path
    }
}
