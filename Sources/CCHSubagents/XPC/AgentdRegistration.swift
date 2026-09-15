import Foundation
import ServiceManagement

/// Registers the cch-agentd LaunchAgent bundled in the app (spike P1/P2c).
public struct SMAppServiceBridge {
    public init() {}

    private var service: SMAppService { SMAppService.agent(plistName: AgentdService.plistName) }

    public func status() -> String {
        switch service.status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }

    public func register() -> String {
        do {
            try service.register()
            return "registered; status=\(status())"
        } catch {
            return "register failed: \(error); status=\(status())"
        }
    }

    public func unregister() -> String {
        do {
            try service.unregister()
            return "unregistered; status=\(status())"
        } catch {
            return "unregister failed: \(error)"
        }
    }

    /// Ensures a reachable helper. A rebuilt ad-hoc bundle makes launchd refuse to spawn the old
    /// registration (exit 78), so an unreachable helper is unregistered and registered again.
    @discardableResult
    public func ensureRunning(ping: () -> Bool) -> String {
        if service.status != .enabled { _ = register() }
        if ping() { return "running" }
        _ = unregister()
        // Registering again while launchd still has the old job fails with EX_CONFIG; wait for it to go.
        for _ in 0..<20 where Self.launchdHasJob() {
            Thread.sleep(forTimeInterval: 0.5)
        }
        _ = register()
        for _ in 0..<10 {
            if ping() { return "running (re-registered)" }
            Thread.sleep(forTimeInterval: 0.5)
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        return "unreachable; status=\(status())"
    }

    static func launchdHasJob() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/dev.cch.agentd"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
