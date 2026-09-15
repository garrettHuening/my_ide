import AppKit
import Combine
import CCHMemory
import CCHSubagents

/// The app's connection to cch-agentd: registers the helper, subscribes to subagent snapshots and
/// terminal output, delivers merge requests into main sessions, and sends user actions.
final class SubagentsClient: NSObject, ObservableObject, PeerXPC {
    static let shared = SubagentsClient()

    @Published private(set) var snapshots: [SubagentSnapshot] = []
    @Published private(set) var connected = false
    /// Category → default model ("" = CLI default), mirrored from the helper's settings.
    @Published private(set) var defaultModels: [String: String] = [:]
    @Published private(set) var autoResume = true

    private weak var app: AppState?
    private let queue = DispatchQueue(label: "cch.subagents.client")
    private var connection: NSXPCConnection?
    private var reconnectScheduled = false
    private var pendingBySession: [Int64: Bool] = [:]

    func start(app: AppState) {
        self.app = app
        queue.async {
            let status = SMAppServiceBridge().ensureRunning {
                if case .success = AgentdConnection().call("ping", timeout: 3) { return true }
                return false
            }
            appLog("[Subagents] helper \(status)")
            self.connect()
        }
    }

    // MARK: Connection

    private func connect() {
        let connection = NSXPCConnection(machServiceName: AgentdService.machName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: AgentdXPC.self)
        connection.exportedInterface = NSXPCInterface(with: PeerXPC.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in self?.connectionLost() }
        connection.interruptionHandler = { [weak self] in self?.connectionLost() }
        connection.resume()
        self.connection = connection
        call("app.subscribe") { result in
            switch result {
            case .success(let list):
                self.connected = true
                self.apply(SubagentSnapshot.decode(list))
                self.refreshSettings()
            case .failure(let error):
                appLog("[Subagents] subscribe failed: \(error.message)", severity: .warning)
                self.connectionLost()
            }
        }
    }

    private func connectionLost() {
        DispatchQueue.main.async { self.connected = false }
        queue.async {
            guard !self.reconnectScheduled else { return }
            self.reconnectScheduled = true
            self.queue.asyncAfter(deadline: .now() + 3) {
                self.reconnectScheduled = false
                self.connect()
            }
        }
    }

    /// Calls the helper; `completion` runs on the main thread.
    func call(_ method: String, _ params: [String: Any] = [:], completion: ((Result<Any, RPCError>) -> Void)? = nil) {
        guard let connection else {
            DispatchQueue.main.async { completion?(.failure(RPCError(message: "Subagent service isn't running"))) }
            return
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            DispatchQueue.main.async { completion?(.failure(RPCError(message: error.localizedDescription))) }
        } as? AgentdXPC
        proxy?.call(RPC.request(method, params)) { data in
            DispatchQueue.main.async { completion?(RPC.parseReply(data)) }
        }
    }

    /// Calls the helper and logs failures to the console.
    func perform(_ method: String, _ params: [String: Any], label: String) {
        call(method, params) { result in
            if case .failure(let error) = result {
                appLog("[Subagents] \(label) failed: \(error.message)", severity: .warning)
                NSSound.beep()
            }
        }
    }

    // MARK: PeerXPC

    func event(_ payload: Data) {
        guard let (type, fields) = RPC.parseEvent(payload) else { return }
        DispatchQueue.main.async {
            switch type {
            case "subagents":
                self.apply(SubagentSnapshot.decode(fields["subagents"] ?? []))
            case "deliverToMain":
                guard let sessionID = (fields["sessionID"] as? Int).map(Int64.init), let text = fields["text"] as? String else { return }
                self.deliverToMain(sessionID: sessionID, text: text)
            default:
                break
            }
        }
    }

    func output(_ agentID: Int64, data: Data) {
        DispatchQueue.main.async { SubagentTerminalRegistry.shared.receive(agentID, data) }
    }

    // MARK: State

    private func apply(_ list: [SubagentSnapshot]) {
        snapshots = list
        guard let sessions = app?.sessions else { return }
        var pending: [Int64: Bool] = [:]
        for s in list where s.subagentState == .needsInput { pending[s.sessionID] = true }
        for sessionID in Set(pending.keys).union(pendingBySession.keys) {
            let value = pending[sessionID] ?? false
            if pendingBySession[sessionID] != value {
                sessions.setPendingAction(sessionID, value)
                pendingBySession[sessionID] = value
            }
        }
    }

    private func deliverToMain(sessionID: Int64, text: String) {
        guard let app, let session = app.sessions.sessions.first(where: { $0.id == sessionID }) else {
            appLog("[Subagents] merge request for unknown session \(sessionID)", severity: .warning)
            return
        }
        app.selectedSubagent[sessionID] = nil
        let alreadyRunning = TerminalRegistry.shared.isRunning(sessionID)
        _ = TerminalRegistry.shared.terminal(for: session)
        DispatchQueue.main.asyncAfter(deadline: .now() + (alreadyRunning ? 0 : 8)) {
            TerminalRegistry.shared.sendMessage(text, to: sessionID)
        }
        appLog("[Subagents] delivered merge request to \(session.name)", severity: .info)
    }

    func snapshots(forSession sessionID: Int64) -> [SubagentSnapshot] {
        snapshots.filter { $0.sessionID == sessionID }
    }

    func snapshot(_ id: Int64) -> SubagentSnapshot? {
        snapshots.first { $0.id == id }
    }

    // MARK: Settings

    func refreshSettings() {
        call("app.settings.get") { result in
            guard case .success(let value) = result, let dict = value as? [String: Any] else { return }
            self.defaultModels = dict["models"] as? [String: String] ?? [:]
            self.autoResume = dict["autoResume"] as? Bool ?? true
        }
    }

    func saveSettings(models: [String: String], autoResume: Bool, completion: @escaping (String?) -> Void) {
        call("app.settings.set", ["models": models, "autoResume": autoResume]) { result in
            switch result {
            case .success(let value):
                if let dict = value as? [String: Any] {
                    self.defaultModels = dict["models"] as? [String: String] ?? [:]
                    self.autoResume = dict["autoResume"] as? Bool ?? true
                }
                completion(nil)
            case .failure(let error):
                completion(error.message)
            }
        }
    }
}
