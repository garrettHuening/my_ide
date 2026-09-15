import Foundation
import ServiceManagement
import SpikeShared

let agent = SMAppService.agent(plistName: "dev.cch.spike.agentd.plist")

func describe(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered: return "notRegistered"
    case .enabled: return "enabled"
    case .requiresApproval: return "requiresApproval"
    case .notFound: return "notFound"
    @unknown default: return "unknown(\(status.rawValue))"
    }
}

let command = CommandLine.arguments.dropFirst().first ?? "status"
switch command {
case "register":
    do {
        try agent.register()
        print("registered; status=\(describe(agent.status))")
    } catch {
        print("register failed: \(error); status=\(describe(agent.status))")
    }
    if agent.status == .requiresApproval {
        SMAppService.openSystemSettingsLoginItems()
    }
case "unregister":
    do {
        try agent.unregister()
        print("unregistered; status=\(describe(agent.status))")
    } catch {
        print("unregister failed: \(error)")
    }
case "status":
    print("status=\(describe(agent.status))")
case "ping":
    print(pingAgentd(from: "app"))
case "grandchild-app":
    let client = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/spike-client").path
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "'\(client)' grandchild-of-app"]
    try process.run()
    process.waitUntilExit()
case "grandchild-agentd":
    let connection = NSXPCConnection(machServiceName: spikeServiceName, options: [])
    connection.remoteObjectInterface = NSXPCInterface(with: SpikeAPI.self)
    connection.resume()
    let done = DispatchSemaphore(value: 0)
    let proxy = connection.remoteObjectProxyWithErrorHandler { error in
        print("ERROR: \(error)")
        done.signal()
    } as! SpikeAPI
    proxy.spawnGrandchild { output in
        print(output)
        done.signal()
    }
    if done.wait(timeout: .now() + 15) == .timedOut { print("TIMEOUT") }
default:
    print("usage: SpikeApp register|status|ping|grandchild-app|grandchild-agentd|unregister")
}
