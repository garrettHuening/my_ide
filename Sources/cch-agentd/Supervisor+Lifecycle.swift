import CCHMemory
import CCHSubagents
import Darwin
import Foundation

extension Supervisor {
    // MARK: Spawn

    struct SpawnRequest {
        let sessionID: Int64
        let sessionDir: String
        let category: SubagentCategory
        let title: String
        let brief: String
        let mergeGroup: String?
        let mergeIndex: Int?
        let model: String?
    }

    func spawn(_ r: SpawnRequest) throws -> String {
        if let model = r.model, !SubagentModel.isValid(model) {
            throw RPCError(message: "Unknown model '\(model)'. Use fable, opus, sonnet, haiku, or a full claude-… model name.")
        }
        guard let repoRoot = git.topLevel(r.sessionDir) else {
            throw RPCError(message: "This session isn't a git repository. Ask the user whether to run `git init` and make a first commit.")
        }
        guard let base = git.head(r.sessionDir) else {
            throw RPCError(message: "This repository has no commits yet. Ask the user whether to make a first commit.")
        }
        var warnings: [String] = []
        let dirty = git.dirtyFiles(r.sessionDir)
        if !dirty.isEmpty {
            warnings.append("Uncommitted changes in main are not visible to the subagent: \(dirty.prefix(20).joined(separator: ", "))")
        }

        let model = SubagentModel.resolve(override: r.model, categoryDefault: try db.defaultModel(for: r.category))
        var s = Subagent(id: 0, sessionID: r.sessionID, sessionDir: r.sessionDir, repoRoot: repoRoot, category: r.category,
                         title: r.title, brief: r.brief, model: model, state: .starting, claudeSessionID: UUID().uuidString.lowercased(),
                         worktreePath: "", branch: "", baseCommit: base, baseBranch: git.branch(r.sessionDir))
        let id = try db.insert(s)
        s = try require(id)
        s.branch = SubagentNaming.branch(category: r.category, id: id, title: r.title)
        s.worktreePath = SubagentNaming.worktreePath(worktreesRoot: Supervisor.worktreesRoot,
                                                     repoRoot: repoRoot, id: id, title: r.title)
        try db.save(s)

        let added = git.addWorktree(repoRoot: repoRoot, path: s.worktreePath, branch: s.branch, base: base)
        guard added.ok else {
            s.failureReason = "git worktree add failed: \(added.stderr)"
            transition(&s, .spawnFailed)
            pushSnapshots()
            throw RPCError(message: s.failureReason ?? "git worktree add failed")
        }

        var groupText = ""
        if let name = r.mergeGroup?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
           let group = try db.group(sessionID: r.sessionID, name: name, create: true) {
            let members = try db.members(groupID: group.id)
            let order = r.mergeIndex.map { MergeOrder.inserting(id, at: $0, into: members) } ?? MergeOrder.appending(id, to: members)
            try db.applyOrder(groupID: group.id, order)
            s = try require(id)
            groupText = " in merge group \"\(name)\" as #\(order[id] ?? 0)"
        }

        try launchHost(&s)
        log(.info, "spawned \(r.category.rawValue) on \(s.branch)\(model.map { " with \($0)" } ?? "")", subagent: s)
        pushSnapshots()
        var text = "Started subagent #\(id) \"\(s.title)\" (\(r.category.rawValue)) on branch \(s.branch)\(groupText)"
        if let model { text += ", model \(model)" }
        text += "."
        if !warnings.isEmpty { text += "\nWarnings:\n- " + warnings.joined(separator: "\n- ") }
        return text
    }

    // MARK: Hosts

    func launchHost(_ s: inout Subagent) throws {
        let hostPath = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("cch-agent-host").path
        guard let pid = Spawner.spawnDetached(executable: hostPath, arguments: ["--agent-id", String(s.id)]) else {
            s.failureReason = "could not start cch-agent-host"
            transition(&s, .spawnFailed)
            throw RPCError(message: "could not start cch-agent-host at \(hostPath)")
        }
        s.hostPID = pid
        s.hostStartedAt = Date()
        try db.save(s)
    }

    func hostHello(_ id: Int64, pid: Int32, connection: NSXPCConnection, reattach: Bool) throws -> [String: Any] {
        var s = try require(id)
        if let existing = hosts[id], existing !== connection {
            existing.invalidate()
        }
        hosts[id] = connection
        s.hostPID = pid
        try db.save(s)
        if let size = terminalSizes[id] { sendToHost(id, "resize", ["cols": size.cols, "rows": size.rows]) }
        pushSnapshots()
        if reattach {
            log(.info, "host reattached (pid \(pid))", subagent: s)
            flushPending(id, after: 0.5)
            return [:]
        }
        guard let claude = ClaudeLocator.findExecutable() else {
            throw RPCError(message: "claude executable not found")
        }
        let resume = resumeOnLaunch.remove(id) != nil
        flushPending(id, after: Self.messageDelayAfterLaunch)
        return launchSpec(for: s, claude: claude, resume: resume)
    }

    func launchSpec(for s: Subagent, claude: String, resume: Bool) -> [String: Any] {
        let plugin = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/plugins/cch-sub").path
        let permission = String(SubagentPrompts.subagentToolPrefix.dropLast(2))
        let settings = "{\"permissions\":{\"allow\":[\"Read\",\"Edit\",\"Write\",\"Glob\",\"Grep\",\"Bash(git:*)\",\"\(permission)\"]}}"
        var args = resume ? ["--resume", s.claudeSessionID] : ["--session-id", s.claudeSessionID]
        args += ["--name", "\(s.category.displayName): \(s.title)"]
        args += SubagentModel.launchArguments(for: s.model)
        args += ["--plugin-dir", plugin, "--permission-mode", "acceptEdits", "--settings", settings,
                 "--append-system-prompt", SubagentPrompts.systemRules(category: s.category, branch: s.branch)]
        if !resume { args.append(s.brief) }

        let cwd = SubagentNaming.workingDirectory(worktreePath: s.worktreePath, sessionDir: s.sessionDir, repoRoot: s.repoRoot)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = userPath
        env["TERM"] = "xterm-256color"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["CCH_ROLE"] = "subagent"
        env["CCH_AGENT_ID"] = String(s.id)
        env["CCH_SESSION_ID"] = String(s.sessionID)
        env["CCH_SESSION_DIR"] = cwd
        env["CCH_TOOL_PREFIX"] = SubagentPrompts.subagentToolPrefix
        return [
            "executable": claude,
            "args": args,
            "env": env.map { "\($0.key)=\($0.value)" },
            "cwd": FileManager.default.fileExists(atPath: cwd) ? cwd : s.worktreePath,
            "autoTrust": ClaudeTrust.isTrusted(s.repoRoot) || ClaudeTrust.isTrusted(s.sessionDir),
            "cols": terminalSizes[s.id]?.cols ?? 120,
            "rows": terminalSizes[s.id]?.rows ?? 40
        ]
    }

    func flushPending(_ id: Int64, after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) {
            guard self.hosts[id] != nil, let messages = self.pendingMessages.removeValue(forKey: id) else { return }
            for (offset, text) in messages.enumerated() {
                self.queue.asyncAfter(deadline: .now() + Double(offset) * 1.5) { self.sendToHost(id, "message", ["text": text]) }
            }
        }
    }

    func hostExited(_ id: Int64, code: Int32) throws {
        hosts.removeValue(forKey: id)
        var s = try require(id)
        s.hostPID = nil
        try db.save(s)
        log(code == 0 ? .info : .warning, "claude exited with code \(code)", subagent: s)
        if code == 0 && [.idle, .complete, .stopped, .merged, .discarded, .merging].contains(s.state) {
            if s.state == .idle || s.state == .complete { try db.setNote(id, "Claude exited — Reopen to continue") }
            pushSnapshots()
            return
        }
        recover(s, abnormal: true)
    }

    func trustPrompt(_ id: Int64, handled: Bool) throws {
        var s = try require(id)
        if handled {
            log(.info, "accepted Claude's folder-trust prompt for the worktree (main repository is trusted)", subagent: s)
        } else {
            transition(&s, .permissionPrompt)
            try db.setNote(id, "Claude is asking whether to trust the worktree folder — answer it in the subagent's terminal")
            pushSnapshots()
        }
    }

    // MARK: User actions

    func stop(_ id: Int64) throws {
        var s = try require(id)
        guard transition(&s, .userStopped) else { throw RPCError(message: "cannot stop a subagent that is \(s.phase)") }
        sendToHost(id, "terminate", [:])
        log(.info, "stopped by user", subagent: s)
        pushSnapshots()
    }

    func reopen(_ id: Int64, nudge: Bool) throws {
        var s = try require(id)
        guard hosts[id] == nil else { return }
        guard FileManager.default.fileExists(atPath: s.worktreePath) else { throw RPCError(message: "worktree is gone") }
        guard transition(&s, .relaunched) else { throw RPCError(message: "cannot reopen a subagent that is \(s.phase)") }
        try db.setNote(id, nil)
        if nudge { queueContinueNudge(s) }
        resumeOnLaunch.insert(id)
        try launchHost(&s)
        pushSnapshots()
    }

    func discard(_ id: Int64) throws {
        var s = try require(id)
        sendToHost(id, "terminate", [:])
        guard transition(&s, .userDiscarded) else { throw RPCError(message: "cannot discard a subagent that is \(s.phase)") }
        queue.asyncAfter(deadline: .now() + 2) {
            self.git.removeWorktree(repoRoot: s.repoRoot, path: s.worktreePath, force: true)
            self.git.deleteBranch(repoRoot: s.repoRoot, branch: s.branch, force: true)
            if let groupID = s.mergeGroupID, let members = try? self.db.members(groupID: groupID) {
                try? self.db.removeFromGroup(s.id)
                try? self.db.applyOrder(groupID: groupID, MergeOrder.removing(s.id, from: members))
            }
            self.pushSnapshots()
        }
        log(.info, "discarded (worktree and branch deleted)", subagent: s)
        pushSnapshots()
    }

    func removeFromGroup(_ id: Int64) throws {
        let s = try require(id)
        guard let groupID = s.mergeGroupID else { return }
        let members = try db.members(groupID: groupID)
        try db.removeFromGroup(id)
        try db.applyOrder(groupID: groupID, MergeOrder.removing(id, from: members))
        pushSnapshots()
    }

    func queueContinueNudge(_ s: Subagent) {
        let commits = git.log(from: s.baseCommit, to: "HEAD", in: s.worktreePath)
        let text = SubagentPrompts.continueNudge(report: try? db.latestReport(subagentID: s.id), commits: commits,
                                                 uncommitted: git.dirtyFiles(s.worktreePath))
        pendingMessages[s.id, default: []].insert(text, at: 0)
    }

    // MARK: Recovery

    func scheduleStartupRecovery() {
        // Hosts that survived a helper restart reconnect within a few seconds; anything still
        // missing after the grace period is treated as dead.
        queue.asyncAfter(deadline: .now() + 8) {
            guard let all = try? self.db.subagents() else { return }
            for s in all where ![.merged, .discarded, .failed, .stopped].contains(s.state) {
                self.recover(s, abnormal: false)
            }
            self.pushSnapshots()
        }
    }

    func recover(_ original: Subagent, abnormal: Bool) {
        var s = original
        let alive = hosts[s.id] != nil
        let autoResume = (try? db.autoResume()) ?? true
        if let last = s.lastResumeAt, Date().timeIntervalSince(last) >= RecoveryPolicy().window { s.resumeCount = 0 }
        let action = RecoveryPlanner.plan(for: s, hostAlive: alive, now: Date(), policy: RecoveryPolicy(autoResume: autoResume))
        switch action {
        case .nothing, .reattach:
            break
        case .awaitManualResume:
            transition(&s, .hostDied)
            try? db.setNote(s.id, "Interrupted — click Resume to continue")
        case .fail(let reason):
            transition(&s, .hostDied)
            s.failureReason = reason
            transition(&s, .crashLoop)
            log(.error, "gave up after repeated crashes", subagent: s)
        case .relaunch(let nudge):
            guard FileManager.default.fileExists(atPath: s.worktreePath) else {
                transition(&s, .hostDied)
                try? db.setNote(s.id, "Worktree is missing; cannot resume")
                break
            }
            transition(&s, .hostDied)
            switch nudge {
            case .none: break
            case .continueWork: queueContinueNudge(s)
            case .commitRequest: pendingMessages[s.id, default: []].append(SubagentPrompts.commitRequest)
            }
            if nudge != .none {
                s.resumeCount += 1
                s.lastResumeAt = Date()
            }
            transition(&s, .relaunched)
            resumeOnLaunch.insert(s.id)
            do {
                try launchHost(&s)
                log(.info, abnormal ? "relaunched after crash" : "resumed after helper restart", subagent: s)
            } catch {
                log(.error, "resume failed: \(error)", subagent: s)
            }
        }
        pushSnapshots()
    }
}

enum Spawner {
    /// posix_spawn in a new session with stdio on /dev/null. Returns the pid.
    static func spawnDetached(executable: String, arguments: [String]) -> Int32? {
        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, executable, &actions, &attributes, argv, environ) == 0 ? pid : nil
    }
}
