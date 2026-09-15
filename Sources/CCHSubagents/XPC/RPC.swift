import Foundation

public enum AgentdService {
    public static let machName = "dev.cch.agentd"
    public static let plistName = "dev.cch.agentd.plist"
    /// Signing identifiers allowed to connect (ad-hoc signatures carry only an identifier).
    public static let codeSigningRequirement =
        "identifier \"dev.cch.ClaudeCodeHub\" or identifier \"dev.cch.mcp\" or identifier \"dev.cch.agent-host\""
}

/// Exported by cch-agentd.
@objc public protocol AgentdXPC {
    /// JSON request `{"method": String, "params": {...}}` → JSON reply `{"ok": Bool, "result"|"error": ...}`.
    func call(_ request: Data, withReply reply: @escaping (Data) -> Void)
    /// Raw PTY bytes from a host.
    func hostOutput(_ agentID: Int64, data: Data)
}

/// Exported by peers (the app and each host) so agentd can push to them.
@objc public protocol PeerXPC {
    /// JSON event `{"type": String, ...}`.
    func event(_ payload: Data)
    /// Raw PTY bytes for a subagent terminal (agentd → app).
    func output(_ agentID: Int64, data: Data)
}

public enum RPC {
    public static func request(_ method: String, _ params: [String: Any] = [:]) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["method": method, "params": params])) ?? Data()
    }

    public static func parseRequest(_ data: Data) -> (method: String, params: [String: Any])? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String else { return nil }
        return (method, object["params"] as? [String: Any] ?? [:])
    }

    public static func ok(_ result: Any = [String: Any]()) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["ok": true, "result": result], options: [.fragmentsAllowed])) ?? Data()
    }

    public static func failure(_ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": message])) ?? Data()
    }

    public static func parseReply(_ data: Data) -> Result<Any, RPCError> {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            return .failure(RPCError(message: "malformed reply"))
        }
        if object["ok"] as? Bool == true { return .success(object["result"] ?? [String: Any]()) }
        return .failure(RPCError(message: object["error"] as? String ?? "unknown error"))
    }

    public static func event(_ type: String, _ fields: [String: Any] = [:]) -> Data {
        var object = fields
        object["type"] = type
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    public static func parseEvent(_ data: Data) -> (type: String, fields: [String: Any])? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        return (type, object)
    }
}

public struct RPCError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }

    public init(message: String) {
        self.message = message
    }
}

/// Synchronous client for short-lived processes (cch-mcp tools and hooks).
public final class AgentdConnection {
    private let connection: NSXPCConnection

    public init() {
        connection = NSXPCConnection(machServiceName: AgentdService.machName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: AgentdXPC.self)
        connection.resume()
    }

    deinit {
        connection.invalidate()
    }

    public func call(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 10) -> Result<Any, RPCError> {
        let done = DispatchSemaphore(value: 0)
        var result: Result<Any, RPCError> = .failure(RPCError(message: "Claude Code Hub subagent service isn't running"))
        let lock = NSLock()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            lock.lock()
            result = .failure(RPCError(message: "Claude Code Hub subagent service isn't running (\(error.localizedDescription))"))
            lock.unlock()
            done.signal()
        } as? AgentdXPC
        guard let proxy else { return result }
        proxy.call(RPC.request(method, params)) { data in
            lock.lock()
            result = RPC.parseReply(data)
            lock.unlock()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            return .failure(RPCError(message: "Claude Code Hub subagent service timed out"))
        }
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
