import Foundation
import Combine
import CCHMemory

/// Runs repo sweeps as headless `claude -p` jobs that write core memories (spec M3).
/// Lives in the app for now; moves into the background helper later. One sweep at a time.
final class SweepRunner: ObservableObject {
    static let shared = SweepRunner()

    /// Project key → project name for sweeps in progress.
    @Published private(set) var running: [String: String] = [:]
    /// Bumped whenever a sweep finishes, so views can reload memories.
    @Published private(set) var completedCount = 0

    private let queue = DispatchQueue(label: "cch.sweep")

    /// Called when a session's terminal starts: sweeps git repos that were never swept or are behind.
    func sweepIfNeeded(workingDir: String) {
        queue.async { self.run(workingDir: workingDir, force: false) }
    }

    /// Session context menu → Re-sweep Project: always a full sweep.
    func sweepNow(workingDir: String) {
        queue.async { self.run(workingDir: workingDir, force: true) }
    }

    private func run(workingDir: String, force: Bool) {
        let console = try? ConsoleLog()
        do {
            let store = try MemoryStore(embedder: nil)
            let git = GitRunner()
            let resolved = ProjectKey.resolve(directory: workingDir)
            let project = try store.project(for: resolved)
            let head = git.output(["rev-parse", "HEAD"], in: workingDir)
            // Automatic sweeps only index code repositories; any folder can be swept by hand.
            guard force || head != nil else { return }
            guard onMain({ self.running[resolved.key] == nil }) else { return }

            let last = try store.lastSweep(projectID: project.id, status: .succeeded)
            let inFlight = try store.lastSweep(projectID: project.id, status: .running)
            var decision: SweepDecision
            if force {
                if let inFlight, Date().timeIntervalSince(inFlight.startedAt) < SweepPolicy.staleRunning { return }
                decision = .full
            } else {
                var commitsSince: Int?
                if let sha = last?.commitSHA, let head {
                    commitsSince = git.output(["rev-list", "--count", "\(sha)..\(head)"], in: workingDir).flatMap { Int($0) }
                }
                decision = SweepPolicy.decide(lastSucceeded: last, running: inFlight, commitsSinceLast: commitsSince,
                                              autoSweep: try store.autoSweep(), now: Date())
            }
            guard decision != .skip else { return }

            var changedFiles: [String] = []
            if case .incremental(let sha) = decision {
                changedFiles = git.output(["diff", "--name-only", "\(sha)..HEAD"], in: workingDir)?
                    .split(separator: "\n").map(String.init) ?? []
                if changedFiles.isEmpty { decision = .full }
            }

            guard let claude = ClaudeLocator.findExecutable() else {
                try? console?.append(domain: "sweep", severity: .error, source: "hub", message: "claude executable not found; sweep skipped", projectID: project.id)
                return
            }
            guard let plugin = HubPlugin.sweepPluginDirectory else {
                try? console?.append(domain: "sweep", severity: .error, source: "hub", message: "cch-sweep plugin missing from the app bundle", projectID: project.id)
                return
            }

            let model = try store.backgroundModel()
            let mode: SweepMode = decision == .full ? .full : .incremental
            let sweepID = try store.startSweep(projectID: project.id, commit: head, mode: mode, model: model)
            DispatchQueue.main.async { self.running[resolved.key] = project.name }
            try? console?.append(domain: "sweep", severity: .info, source: "hub",
                                 message: "Started \(mode.rawValue) sweep of \(project.name) with \(model)", projectID: project.id)
            appLog("[Sweep] start \(mode.rawValue) project=\(project.name) model=\(model)")

            let root = git.output(["rev-parse", "--show-toplevel"], in: workingDir) ?? workingDir
            let result = runClaude(claude: claude, directory: root, workingDir: workingDir, sweepID: sweepID,
                                   arguments: SweepPrompt.arguments(prompt: SweepPrompt.text(mode: decision, changedFiles: changedFiles),
                                                                    pluginDirectory: plugin, model: model))

            try store.finishSweep(id: sweepID, projectID: project.id, succeeded: result.succeeded, costUSD: result.cost, error: result.error)
            let added = try store.sweepMemoriesAdded(sweepID: sweepID) ?? 0
            let cost = result.cost.map { String(format: " · $%.2f", $0) } ?? ""
            try? console?.append(domain: "sweep", severity: result.succeeded ? .info : .error, source: "hub",
                                 message: result.succeeded
                                    ? "Finished \(mode.rawValue) sweep of \(project.name): \(added) new memories\(cost). \(result.summary)"
                                    : "Sweep of \(project.name) failed: \(result.error ?? "unknown error")",
                                 projectID: project.id)
            appLog("[Sweep] done project=\(project.name) ok=\(result.succeeded) added=\(added)")
            DispatchQueue.main.async {
                self.running.removeValue(forKey: resolved.key)
                self.completedCount += 1
            }
        } catch {
            try? console?.append(domain: "sweep", severity: .error, source: "hub", message: "Sweep error: \(error)")
            appLog("[Sweep] error \(error)")
        }
    }

    private struct Result {
        let succeeded: Bool
        let cost: Double?
        let summary: String
        let error: String?
    }

    private func runClaude(claude: String, directory: String, workingDir: String, sweepID: Int64, arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment
        environment["CCH_ROLE"] = "sweep"
        environment["CCH_SESSION_DIR"] = workingDir
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let logDir = MemoryPaths.supportDirectory + "/sweeps"
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        let stderrPath = logDir + "/\(sweepID).stderr.log"
        FileManager.default.createFile(atPath: stderrPath, contents: nil)
        process.standardError = FileHandle(forWritingAtPath: stderrPath)
        let stdout = Pipe()
        process.standardOutput = stdout

        do {
            try process.run()
        } catch {
            return Result(succeeded: false, cost: nil, summary: "", error: "could not start claude: \(error)")
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let resultText = json?["result"] as? String ?? String(data: data, encoding: .utf8) ?? ""
        let isError = json?["is_error"] as? Bool ?? true
        let succeeded = process.terminationStatus == 0 && !isError
        let summary = resultText.split(separator: "\n").last(where: { $0.hasPrefix("Swept:") }).map(String.init) ?? ""
        return Result(succeeded: succeeded, cost: json?["total_cost_usd"] as? Double, summary: summary,
                      error: succeeded ? nil : "exit \(process.terminationStatus): \(resultText.prefix(300)) (stderr: \(stderrPath))")
    }

    private func onMain<T>(_ body: @escaping () -> T) -> T {
        if Thread.isMainThread { return body() }
        return DispatchQueue.main.sync(execute: body)
    }
}
