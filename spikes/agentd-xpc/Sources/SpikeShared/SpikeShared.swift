import Foundation

public let spikeServiceName = "dev.cch.spike.agentd"

@objc public protocol SpikeAPI {
    func ping(_ from: String, reply: @escaping (String) -> Void)
    func spawnGrandchild(reply: @escaping (String) -> Void)
}

public func spikeLog(_ message: String) {
    let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/cch-spike.log")
    let line = "\(Date()) [\(ProcessInfo.processInfo.processName) pid=\(getpid())] \(message)\n"
    let data = Data(line.utf8)
    FileHandle.standardError.write(data)
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: url)
    }
}

/// Connects to the spike agent, sends one ping, and returns the reply or an error string.
public func pingAgentd(from: String, timeout: TimeInterval = 5) -> String {
    let connection = NSXPCConnection(machServiceName: spikeServiceName, options: [])
    connection.remoteObjectInterface = NSXPCInterface(with: SpikeAPI.self)
    connection.resume()
    let done = DispatchSemaphore(value: 0)
    var result = "TIMEOUT"
    let proxy = connection.remoteObjectProxyWithErrorHandler { error in
        result = "ERROR: \(error)"
        done.signal()
    } as! SpikeAPI
    proxy.ping(from) { reply in
        result = reply
        done.signal()
    }
    _ = done.wait(timeout: .now() + timeout)
    connection.invalidate()
    return result
}
