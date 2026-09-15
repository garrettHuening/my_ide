import CCHSubagents
import CForkpty
import Darwin
import Foundation

// cch-agent-host --agent-id N
// One process per subagent: runs `claude` in a pseudo-terminal inside the subagent's worktree,
// streams its output to cch-agentd and applies input, resizes and messages. Survives helper
// restarts by reconnecting.

setvbuf(stdout, nil, _IOLBF, 0)

guard let idIndex = CommandLine.arguments.firstIndex(of: "--agent-id"),
      idIndex + 1 < CommandLine.arguments.count,
      let agentID = Int64(CommandLine.arguments[idIndex + 1]) else {
    FileHandle.standardError.write(Data("usage: cch-agent-host --agent-id N\n".utf8))
    exit(2)
}

final class Host: NSObject, PeerXPC {
    let agentID: Int64
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var masterFD: Int32 = -1
    private var childPID: pid_t = 0
    private var autoTrust = false
    private var trustHandled = false
    private var screenLetters = ""
    private var pendingOutput = Data()
    private let started = Date()
    private var reconnecting = false

    init(agentID: Int64) {
        self.agentID = agentID
    }

    // MARK: Startup

    func run() {
        var spec: [String: Any]?
        for attempt in 0..<15 {
            connect()
            if case .success(let result) = call("host.hello", ["id": Int(agentID), "pid": Int(getpid())]), let s = result as? [String: Any] {
                spec = s
                break
            }
            Thread.sleep(forTimeInterval: attempt < 5 ? 1 : 3)
        }
        guard let spec, let executable = spec["executable"] as? String else { exit(1) }
        autoTrust = spec["autoTrust"] as? Bool ?? false
        startChild(executable: executable, args: spec["args"] as? [String] ?? [], env: spec["env"] as? [String] ?? [],
                   cwd: spec["cwd"] as? String ?? NSHomeDirectory(),
                   cols: spec["cols"] as? Int ?? 120, rows: spec["rows"] as? Int ?? 40)
        RunLoop.main.run()
    }

    private func startChild(executable: String, args: [String], env: [String], cwd: String, cols: Int, rows: Int) {
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        let cExecutable = strdup(executable)
        let cArgs: [UnsafeMutablePointer<CChar>?] = ([executable] + args).map { strdup($0) } + [nil]
        let cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup($0) } + [nil]
        let cCwd = strdup(cwd)
        var master: Int32 = -1

        let pid = cforkpty_open(&master, nil, nil, &size)
        if pid == 0 {
            // Child: only async-signal-safe calls until exec.
            _ = chdir(cCwd)
            execve(cExecutable, cArgs, cEnv)
            _exit(127)
        }
        guard pid > 0 else { exit(1) }
        masterFD = master
        childPID = pid

        Thread.detachNewThread { self.readLoop() }
        Thread.detachNewThread { self.waitForChild() }
    }

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(masterFD, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            handleOutput(Data(buffer[0..<count]))
        }
    }

    private func waitForChild() {
        var status: Int32 = 0
        while waitpid(childPID, &status, 0) < 0 && errno == EINTR {}
        let exited = (status & 0x7f) == 0
        let code = exited ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        Thread.sleep(forTimeInterval: 0.3)
        _ = call("host.exited", ["id": Int(agentID), "code": Int(code)], timeout: 5)
        exit(0)
    }

    // MARK: Output

    private func handleOutput(_ data: Data) {
        detectTrustPrompt(data)
        lock.lock()
        let proxy = connection.flatMap { $0.remoteObjectProxyWithErrorHandler { _ in } as? AgentdXPC }
        if proxy == nil || reconnecting {
            pendingOutput.append(data)
            if pendingOutput.count > 1_048_576 { pendingOutput = pendingOutput.suffix(1_048_576) }
            lock.unlock()
            return
        }
        lock.unlock()
        proxy?.hostOutput(agentID, data: data)
    }

    private func detectTrustPrompt(_ data: Data) {
        guard !trustHandled, Date().timeIntervalSince(started) < 120 else { return }
        // Keep raw text (escape sequences may span chunks) and test the stripped form.
        screenLetters = String((screenLetters + String(decoding: data, as: UTF8.self)).suffix(40_000))
        guard ClaudeTrust.isTrustPrompt(screenLetters) else { return }
        trustHandled = true
        if autoTrust {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                self.write(Data("\u{1b}[B".utf8))
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { self.write(Data("\r".utf8)) }
            }
        }
        DispatchQueue.global().async { _ = self.call("host.trustPrompt", ["id": Int(self.agentID), "handled": self.autoTrust]) }
    }

    private func write(_ data: Data) {
        guard masterFD >= 0 else { return }
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(masterFD, pointer, remaining)
                if written < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
    }

    // MARK: PeerXPC

    func event(_ payload: Data) {
        guard let (type, fields) = RPC.parseEvent(payload) else { return }
        switch type {
        case "input":
            if let data = (fields["data"] as? String).flatMap({ Data(base64Encoded: $0) }) { write(data) }
        case "message":
            guard let text = fields["text"] as? String else { return }
            write(Data("\u{1b}[200~".utf8) + Data(text.utf8) + Data("\u{1b}[201~".utf8))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) { self.write(Data("\r".utf8)) }
        case "resize":
            if let cols = fields["cols"] as? Int, let rows = fields["rows"] as? Int, masterFD >= 0 {
                _ = cforkpty_setwinsize(masterFD, UInt16(rows), UInt16(cols))
            }
        case "terminate":
            guard childPID > 0 else { exit(0) }
            kill(childPID, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { kill(self.childPID, SIGKILL) }
        default:
            break
        }
    }

    func output(_ agentID: Int64, data: Data) {}

    // MARK: Connection

    private func connect() {
        let connection = NSXPCConnection(machServiceName: AgentdService.machName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: AgentdXPC.self)
        connection.exportedInterface = NSXPCInterface(with: PeerXPC.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in self?.connectionLost() }
        connection.interruptionHandler = { [weak self] in self?.connectionLost() }
        connection.resume()
        lock.lock()
        self.connection = connection
        lock.unlock()
    }

    private func connectionLost() {
        lock.lock()
        guard !reconnecting else {
            lock.unlock()
            return
        }
        reconnecting = true
        connection = nil
        lock.unlock()
        DispatchQueue.global().async { self.reconnectLoop() }
    }

    private func reconnectLoop() {
        while true {
            Thread.sleep(forTimeInterval: 2)
            connect()
            if case .success = call("host.reattach", ["id": Int(agentID), "pid": Int(getpid())], timeout: 5) {
                lock.lock()
                let backlog = pendingOutput
                pendingOutput = Data()
                reconnecting = false
                let proxy = connection.flatMap { $0.remoteObjectProxyWithErrorHandler { _ in } as? AgentdXPC }
                lock.unlock()
                if !backlog.isEmpty { proxy?.hostOutput(agentID, data: backlog) }
                return
            }
        }
    }

    private func call(_ method: String, _ params: [String: Any], timeout: TimeInterval = 10) -> Result<Any, RPCError> {
        lock.lock()
        let connection = self.connection
        lock.unlock()
        guard let connection else { return .failure(RPCError(message: "not connected")) }
        let done = DispatchSemaphore(value: 0)
        var result: Result<Any, RPCError> = .failure(RPCError(message: "no reply"))
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            result = .failure(RPCError(message: "\(error)"))
            done.signal()
        } as? AgentdXPC
        proxy?.call(RPC.request(method, params)) { data in
            result = RPC.parseReply(data)
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut { return .failure(RPCError(message: "timeout")) }
        return result
    }
}

signal(SIGPIPE, SIG_IGN)
Host(agentID: agentID).run()
