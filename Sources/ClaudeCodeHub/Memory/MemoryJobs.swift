import Foundation
import Combine
import CCHMemory

/// Background core-memory jobs run as headless `claude -p`: repo sweeps (M3), dreaming (M6) and
/// documentation ingestion (M4). One job at a time to bound cost. Lives in the app until the
/// background helper takes it over.
final class MemoryJobs: ObservableObject {
    static let shared = MemoryJobs()

    enum Kind: String {
        case sweep, dream, docs
    }

    /// Job id (`kind:projectKey`) → label for the status bar.
    @Published private(set) var running: [String: String] = [:]
    /// Bumped whenever a job finishes, so views can reload memories.
    @Published private(set) var completedCount = 0

    private let queue = DispatchQueue(label: "cch.memory-jobs")
    private var dreamTimer: Timer?

    static func jobID(_ kind: Kind, _ projectKey: String) -> String { "\(kind.rawValue):\(projectKey)" }

    // MARK: Sweep

    /// Called when a session's terminal starts: sweeps git repos that were never swept or are behind.
    func sweepIfNeeded(workingDir: String) {
        queue.async { self.sweep(workingDir: workingDir, force: false) }
    }

    /// Session context menu → Re-sweep Project: always a full sweep.
    func sweepNow(workingDir: String) {
        queue.async { self.sweep(workingDir: workingDir, force: true) }
    }

    private func sweep(workingDir: String, force: Bool) {
        let console = try? ConsoleLog()
        do {
            let store = try MemoryStore(embedder: nil)
            let git = GitRunner()
            let resolved = ProjectKey.resolve(directory: workingDir)
            let project = try store.project(for: resolved)
            let head = git.output(["rev-parse", "HEAD"], in: workingDir)
            // Automatic sweeps only index code repositories; any folder can be swept by hand.
            guard force || head != nil else { return }

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
            guard let (claude, plugin) = prerequisites(plugin: HubPlugin.sweepPluginDirectory, domain: "sweep", projectID: project.id, console: console) else { return }

            let model = try store.backgroundModel()
            let mode: SweepMode = decision == .full ? .full : .incremental
            let sweepID = try store.startSweep(projectID: project.id, commit: head, mode: mode, model: model)
            let job = Self.jobID(.sweep, resolved.key)
            begin(job, label: "indexing \(project.name)")
            try? console?.append(domain: "sweep", severity: .info, source: "hub", message: "Started \(mode.rawValue) sweep of \(project.name) with \(model)", projectID: project.id)

            let root = git.output(["rev-parse", "--show-toplevel"], in: workingDir) ?? workingDir
            let result = HeadlessClaude.run(
                claude: claude,
                arguments: SweepPrompt.arguments(prompt: SweepPrompt.text(mode: decision, changedFiles: changedFiles), pluginDirectory: plugin, model: model),
                directory: root, environment: ["CCH_ROLE": "sweep", "CCH_SESSION_DIR": workingDir],
                stderrPath: stderrPath("sweep-\(sweepID)"))
            try store.finishSweep(id: sweepID, projectID: project.id, succeeded: result.succeeded, costUSD: result.costUSD, error: result.error)
            let added = try store.sweepMemoriesAdded(sweepID: sweepID) ?? 0
            try? console?.append(domain: "sweep", severity: result.succeeded ? .info : .error, source: "hub",
                                 message: result.succeeded
                                    ? "Finished \(mode.rawValue) sweep of \(project.name): \(added) new memories\(cost(result)). \(result.summaryLine(prefix: "Swept:"))"
                                    : "Sweep of \(project.name) failed: \(result.error ?? "unknown error")",
                                 projectID: project.id)
            end(job)
        } catch {
            try? console?.append(domain: "sweep", severity: .error, source: "hub", message: "Sweep error: \(error)")
        }
    }

    // MARK: Dreaming

    /// Checks every 15 minutes (and shortly after launch) for projects due for a dream.
    func startDreamScheduler() {
        DispatchQueue.main.async {
            guard self.dreamTimer == nil else { return }
            self.dreamTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in self?.dreamDueProjects() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) { self.dreamDueProjects() }
        }
    }

    func dreamDueProjects() {
        queue.async {
            guard let store = try? MemoryStore(embedder: nil), (try? store.dreamingEnabled()) == true,
                  let projects = try? store.projects() else { return }
            for project in projects where FileManager.default.fileExists(atPath: project.root) {
                self.dream(project: project, store: store, force: false)
            }
        }
    }

    /// Session context menu → Dream Now: ignores the 6-hour interval (still needs changed memories).
    func dreamNow(workingDir: String) {
        queue.async {
            guard let store = try? MemoryStore(embedder: nil),
                  let project = try? store.project(for: ProjectKey.resolve(directory: workingDir)) else { return }
            self.dream(project: project, store: store, force: true)
        }
    }

    private func dream(project: Project, store: MemoryStore, force: Bool) {
        let console = try? ConsoleLog()
        do {
            let last = try store.lastDream(projectID: project.id, status: "succeeded")
            let since = last.map { $0.finishedAt ?? $0.startedAt } ?? .distantPast
            let changed = try store.changedMemoryCount(projectID: project.id, since: since)
            let running = try store.lastDream(projectID: project.id, status: "running")?.startedAt
            guard Dreaming.isDue(enabled: true, lastSucceeded: force ? nil : last?.finishedAt, runningSince: running,
                                 changedSinceLast: changed, now: Date()) else {
                if force { try? console?.append(domain: "dreaming", severity: .info, source: "hub", message: "Nothing to dream about in \(project.name): no memories changed since the last dream", projectID: project.id) }
                return
            }
            guard let (claude, plugin) = prerequisites(plugin: HubPlugin.dreamPluginDirectory, domain: "dreaming", projectID: project.id, console: console) else { return }

            let model = try store.backgroundModel()
            let candidates = min(changed, Dreaming.candidateLimit)
            let dreamID = try store.startDream(projectID: project.id, since: since, candidates: candidates, model: model)
            let job = Self.jobID(.dream, project.key)
            begin(job, label: "dreaming \(project.name)")
            try? console?.append(domain: "dreaming", severity: .info, source: "hub", message: "Dreaming over \(candidates) changed memories in \(project.name) with \(model)", projectID: project.id)

            let result = HeadlessClaude.run(
                claude: claude,
                arguments: Dreaming.arguments(prompt: Dreaming.prompt(projectName: project.name, candidateCount: candidates), pluginDirectory: plugin, model: model),
                directory: project.root, environment: ["CCH_ROLE": "dream", "CCH_SESSION_DIR": project.root],
                stderrPath: stderrPath("dream-\(dreamID)"))
            let summary = result.summaryLine(prefix: "Dreamed:")
            try store.finishDream(id: dreamID, succeeded: result.succeeded, costUSD: result.costUSD, summary: summary, error: result.error)
            try? console?.append(domain: "dreaming", severity: result.succeeded ? .info : .error, source: "hub",
                                 message: result.succeeded ? "Dreamed \(project.name)\(cost(result)). \(summary)" : "Dreaming \(project.name) failed: \(result.error ?? "unknown error")",
                                 projectID: project.id)
            end(job)
        } catch {
            try? console?.append(domain: "dreaming", severity: .error, source: "hub", message: "Dreaming error: \(error)", projectID: project.id)
        }
    }

    // MARK: Documentation

    /// Session context menu → Add Documentation: a URL, a file or a folder.
    func ingestDocs(source: String, workingDir: String) {
        queue.async {
            let console = try? ConsoleLog()
            do {
                let store = try MemoryStore(embedder: nil)
                let resolved = ProjectKey.resolve(directory: workingDir)
                let project = try store.project(for: resolved)
                guard let (claude, plugin) = self.prerequisites(plugin: HubPlugin.docsPluginDirectory, domain: "docs", projectID: project.id, console: console) else { return }
                let model = try store.backgroundModel()
                let isURL = source.hasPrefix("http://") || source.hasPrefix("https://")
                let ingestionID = try store.startIngestion(projectID: project.id, source: source)
                let job = Self.jobID(.docs, resolved.key)
                self.begin(job, label: "reading docs for \(project.name)")
                try? console?.append(domain: "docs", severity: .info, source: "hub", message: "Ingesting \(source) into \(project.name) with \(model)", projectID: project.id)

                var arguments = DocsIngestion.arguments(prompt: DocsIngestion.prompt(projectName: project.name, source: source),
                                                        pluginDirectory: plugin, model: model, allowWeb: isURL)
                if !isURL { arguments += ["--add-dir", source] }
                let result = HeadlessClaude.run(claude: claude, arguments: arguments, directory: resolved.root,
                                                environment: ["CCH_ROLE": "docs", "CCH_SESSION_DIR": workingDir],
                                                stderrPath: self.stderrPath("docs-\(ingestionID)"))
                let added = try store.finishIngestion(id: ingestionID, projectID: project.id, succeeded: result.succeeded, costUSD: result.costUSD, error: result.error)
                try? console?.append(domain: "docs", severity: result.succeeded ? .info : .error, source: "hub",
                                     message: result.succeeded
                                        ? "Ingested \(source): \(added) new memories\(self.cost(result)). \(result.summaryLine(prefix: "Ingested:"))"
                                        : "Ingesting \(source) failed: \(result.error ?? "unknown error")",
                                     projectID: project.id)
                self.end(job)
            } catch {
                try? console?.append(domain: "docs", severity: .error, source: "hub", message: "Documentation ingestion error: \(error)")
            }
        }
    }

    // MARK: Helpers

    func isRunning(_ kind: Kind, projectKey: String) -> Bool {
        running[Self.jobID(kind, projectKey)] != nil
    }

    private func prerequisites(plugin: String?, domain: String, projectID: Int64, console: ConsoleLog?) -> (String, String)? {
        guard let claude = ClaudeLocator.findExecutable() else {
            try? console?.append(domain: domain, severity: .error, source: "hub", message: "claude executable not found; job skipped", projectID: projectID)
            return nil
        }
        guard let plugin else {
            try? console?.append(domain: domain, severity: .error, source: "hub", message: "plugin missing from the app bundle; job skipped", projectID: projectID)
            return nil
        }
        return (claude, plugin)
    }

    private func begin(_ job: String, label: String) {
        DispatchQueue.main.async { self.running[job] = label }
        appLog("[MemoryJobs] start \(job)")
    }

    private func end(_ job: String) {
        appLog("[MemoryJobs] done \(job)")
        DispatchQueue.main.async {
            self.running.removeValue(forKey: job)
            self.completedCount += 1
        }
    }

    private func stderrPath(_ name: String) -> String {
        let dir = MemoryPaths.supportDirectory + "/jobs"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/\(name).stderr.log"
    }

    private func cost(_ result: HeadlessResult) -> String {
        result.costUSD.map { String(format: " · $%.2f", $0) } ?? ""
    }
}
