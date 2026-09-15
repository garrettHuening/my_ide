import CCHMemory
import CCHSubagents
import Foundation

extension Supervisor {
    /// Merge button (spec §5).
    func requestMerge(_ id: Int64) throws -> [String: Any] {
        var s = try require(id)
        let members = try s.mergeGroupID.map { try db.members(groupID: $0) } ?? []
        let worktreeExists = FileManager.default.fileExists(atPath: s.worktreePath)
        let hasCommits = worktreeExists && git.commitCount(from: s.baseCommit, to: "HEAD", in: s.worktreePath) > 0
        let isDirty = worktreeExists && !git.dirtyFiles(s.worktreePath).isEmpty

        switch MergeGate.evaluate(s, groupMembers: members, hasCommits: hasCommits, isDirty: isDirty) {
        case .failure(.busy):
            throw RPCError(message: "#\(id) is busy; wait until its turn finishes")
        case .failure(.waitsOn(let index)):
            throw RPCError(message: "#\(id) must wait until merge group member #\(index) is merged")
        case .failure(.notMergeable):
            throw RPCError(message: "#\(id) is \(s.state.rawValue) and can't be merged")
        case .success(.archiveNothingToMerge):
            transition(&s, .archivedNothingToMerge)
            s.mergedAt = Date()
            try db.save(s)
            cleanUp(s)
            log(.info, "archived: nothing to merge", subagent: s)
            pushSnapshots()
            return ["result": "archived"]
        case .success(.resend):
            return ["result": try deliverMergeRequest(&s) ? "resent" : "held"]
        case .success(.merge):
            if isDirty {
                transition(&s, .mergeRequested(needsCommit: true))
                deliverOrReopen(&s, SubagentPrompts.commitRequest)
                startCommitWait(id)
                log(.info, "merge requested; asked the subagent to commit first", subagent: s)
                pushSnapshots()
                return ["result": "awaiting_commit"]
            }
            transition(&s, .mergeRequested(needsCommit: false))
            return ["result": try deliverMergeRequest(&s) ? "delivered" : "held"]
        }
    }

    func deliverOrReopen(_ s: inout Subagent, _ text: String) {
        if hosts[s.id] != nil {
            deliver(s.id, text)
            return
        }
        pendingMessages[s.id, default: []].append(text)
        resumeOnLaunch.insert(s.id)
        try? launchHost(&s)
    }

    func startCommitWait(_ id: Int64) {
        commitWaitGeneration[id, default: 0] += 1
        let generation = commitWaitGeneration[id] ?? 0
        queue.asyncAfter(deadline: .now() + Self.commitWaitTimeout) {
            guard self.commitWaitGeneration[id] == generation, var s = try? self.db.subagent(id: id),
                  s.state == .merging, s.mergeSubstate == .awaitingCommit else { return }
            self.transition(&s, .mergeCancelled(wasComplete: s.completedAt != nil))
            try? self.db.setNote(id, "Commit timed out; merge cancelled")
            self.log(.warning, "commit wait timed out; merge cancelled", subagent: s)
            self.pushSnapshots()
        }
    }

    @discardableResult
    func deliverMergeRequest(_ s: inout Subagent) throws -> Bool {
        guard let tip = git.tip(of: s.branch, in: s.repoRoot) else { throw RPCError(message: "branch \(s.branch) not found") }
        s.mergeTip = tip
        try db.save(s)
        let summary = try db.latestReport(subagentID: s.id)?.summary ?? ""
        let text = SubagentPrompts.mergeRequest(subagent: s, summary: summary,
                                                commits: git.log(from: s.baseCommit, to: tip, in: s.repoRoot),
                                                diffStat: git.diffStat(from: s.baseCommit, to: tip, in: s.repoRoot))
        let delivered = pushToApps("deliverToMain", ["sessionID": Int(s.sessionID), "agentID": Int(s.id), "text": text])
        if delivered {
            try db.setNote(s.id, "Merge request sent to the main session")
            log(.info, "merge request delivered to the main session", subagent: s)
        } else {
            try db.setNote(s.id, "Open Claude Code Hub, then Re-send Merge")
            log(.warning, "no Hub window connected; merge request not delivered", subagent: s)
        }
        pushSnapshots()
        return delivered
    }

    func verifyMerge(_ id: Int64, mergeCommit: String?) throws -> String {
        var s = try require(id)
        guard s.state == .merging, s.mergeSubstate == .awaitingMain, let tip = s.mergeTip else {
            throw RPCError(message: "#\(id) has no pending merge request")
        }
        guard git.isAncestor(tip, of: "HEAD", in: s.sessionDir) else {
            throw RPCError(message: "merge_tip \(tip.prefix(7)) is not in HEAD yet; merge \(s.branch) first")
        }
        if let current = git.tip(of: s.branch, in: s.repoRoot), current != tip {
            transition(&s, .mergedWithNewerCommits)
            try db.setNote(id, "New commits after the merge; merge again to include them")
            pushSnapshots()
            return "Merged, but #\(id) committed more after the request; its branch was kept. Merge again later to include the new commits."
        }
        transition(&s, .mergeVerified)
        s.mergedAt = Date()
        try db.save(s)
        try db.setNote(id, nil)
        cleanUp(s)
        log(.info, "merged\(mergeCommit.map { " in \($0.prefix(7))" } ?? "")", subagent: s)
        pushSnapshots()
        var text = "Verified: #\(id) \"\(s.title)\" is merged. Its worktree and branch are being cleaned up."
        if let groupID = s.mergeGroupID {
            let next = try db.members(groupID: groupID).filter { $0.state != .merged && $0.state != .discarded }.min { ($0.mergeIndex ?? .max) < ($1.mergeIndex ?? .max) }
            if let next { text += " Next in its merge group: #\(next.id) \"\(next.title)\"." }
        }
        return text
    }

    func failMerge(_ id: Int64, reason: String) throws -> String {
        var s = try require(id)
        guard s.state == .merging else { throw RPCError(message: "#\(id) has no pending merge") }
        commitWaitGeneration[id, default: 0] += 1
        transition(&s, .mergeCancelled(wasComplete: s.completedAt != nil))
        try db.setNote(id, "Merge failed: \(reason)")
        log(.warning, "merge failed: \(reason)", subagent: s)
        pushSnapshots()
        return "Recorded: merge of #\(id) failed."
    }

    /// Stops the host, removes the worktree and deletes the merged branch (D8).
    func cleanUp(_ s: Subagent) {
        sendToHost(s.id, "terminate", [:])
        queue.asyncAfter(deadline: .now() + 3) {
            let removed = self.git.removeWorktree(repoRoot: s.repoRoot, path: s.worktreePath, force: false)
            if removed.ok {
                let deleted = self.git.deleteBranch(repoRoot: s.repoRoot, branch: s.branch, force: false)
                if !deleted.ok { try? self.db.setNote(s.id, "Branch kept: \(deleted.stderr)") }
            } else if FileManager.default.fileExists(atPath: s.worktreePath) {
                try? self.db.setNote(s.id, "Worktree not removed: \(removed.stderr)")
                self.log(.warning, "worktree not removed: \(removed.stderr)", subagent: s)
            }
            self.pushSnapshots()
        }
    }
}
