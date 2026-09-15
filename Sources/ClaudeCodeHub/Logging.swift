import Foundation

private let logURL: URL = {
    let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Logs", isDirectory: true)
    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    return logs.appendingPathComponent("ClaudeCodeHub.log")
}()

private let logQueue = DispatchQueue(label: "cch.log")

private let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

func appLog(_ message: String) {
    let line = "\(timeFormatter.string(from: Date())) \(message)\n"
    fputs(line, stderr)
    logQueue.async {
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: logURL)
            }
        }
    }
}
