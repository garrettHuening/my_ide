import Foundation
import SpikeShared

final class Service: NSObject, NSXPCListenerDelegate, SpikeAPI {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        spikeLog("accept pid=\(connection.processIdentifier)")
        // P1b: ad-hoc signatures carry an identifier; prove the requirement is enforced.
        connection.setCodeSigningRequirement(
            "identifier \"dev.cch.spike.app\" or identifier \"dev.cch.spike.client\""
        )
        connection.exportedInterface = NSXPCInterface(with: SpikeAPI.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func ping(_ from: String, reply: @escaping (String) -> Void) {
        spikeLog("ping from \(from)")
        reply("pong from agentd pid=\(getpid()) to \(from)")
    }

    /// agentd → /bin/sh → spike-client, mimicking agentd → host → claude → cch-mcp.
    func spawnGrandchild(reply: @escaping (String) -> Void) {
        let client = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("spike-client").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "'\(client)' grandchild-of-agentd"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            reply("spawn failed: \(error)")
            return
        }
        DispatchQueue.global().async {
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            reply(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

spikeLog("agentd starting")
let service = Service()
let listener = NSXPCListener(machServiceName: spikeServiceName)
listener.delegate = service
listener.resume()
RunLoop.main.run()
