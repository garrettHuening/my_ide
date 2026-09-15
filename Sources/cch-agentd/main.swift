import CCHSubagents
import Foundation

// cch-agentd — Claude Code Hub's background helper (LaunchAgent, Mach service dev.cch.agentd).
// Owns agents.db, git worktrees, one cch-agent-host process per subagent, subagent tools, hooks,
// merges and crash recovery. Subagents keep running when the app quits.

setvbuf(stdout, nil, _IOLBF, 0)
let supervisor: Supervisor
do {
    supervisor = try Supervisor()
} catch {
    FileHandle.standardError.write(Data("cch-agentd: cannot start: \(error)\n".utf8))
    exit(1)
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(AgentdService.codeSigningRequirement)
        let handler = ConnectionHandler(connection: connection, supervisor: supervisor)
        connection.exportedInterface = NSXPCInterface(with: AgentdXPC.self)
        connection.exportedObject = handler
        connection.remoteObjectInterface = NSXPCInterface(with: PeerXPC.self)
        connection.invalidationHandler = { [weak connection] in
            guard let connection else { return }
            supervisor.connectionClosed(connection)
        }
        connection.resume()
        return true
    }
}

final class ConnectionHandler: NSObject, AgentdXPC {
    weak var connection: NSXPCConnection?
    let supervisor: Supervisor

    init(connection: NSXPCConnection, supervisor: Supervisor) {
        self.connection = connection
        self.supervisor = supervisor
    }

    func call(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard let (method, params) = RPC.parseRequest(request), let connection else {
            reply(RPC.failure("malformed request"))
            return
        }
        supervisor.handle(method: method, params: params, from: connection, reply: reply)
    }

    func hostOutput(_ agentID: Int64, data: Data) {
        supervisor.hostOutput(agentID: agentID, data: data)
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: AgentdService.machName)
listener.delegate = delegate
listener.resume()
supervisor.log(.info, "cch-agentd started (pid \(getpid()))")
supervisor.scheduleStartupRecovery()
RunLoop.main.run()
