import CCHMemory
import CCHSubagents
import Foundation

extension Supervisor {
    // MARK: Tools

    func tool(name: String, args: [String: Any], caller: [String: Any]) throws -> String {
        let role = caller["role"] as? String ?? ""
        let sessionID = Int64(caller["sessionID"] as? Int ?? 0)
        let agentID = (caller["agentID"] as? Int).map(Int64.init)

        switch (role, name) {
        case ("main", "spawn_subagent"):
            guard sessionID > 0, let dir = caller["sessionDir"] as? String else { throw RPCError(message: "spawn_subagent is only available in Claude Code Hub sessions") }
            guard let category = (args["category"] as? String).flatMap(SubagentCategory.init(rawValue:)) else {
                throw RPCError(message: "category must be one of: task, bug, feature, helper")
            }
            let title = (args["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let brief = (args["brief"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !brief.isEmpty else { throw RPCError(message: "title and brief are required") }
            let model = (args["model"] as? String).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
            return try spawn(SpawnRequest(sessionID: sessionID, sessionDir: dir, category: category, title: title, brief: brief,
                                          mergeGroup: args["merge_group"] as? String, mergeIndex: args["merge_index"] as? Int, model: model))

        case ("main", "list_subagents"):
            let list = try db.subagents(sessionID: sessionID).filter { $0.state != .discarded }
            guard !list.isEmpty else { return "No subagents in this session." }
            return try list.map { s in
                var line = "#\(s.id) [\(s.category.rawValue)] \"\(s.title)\" · \(s.phase)"
                if let model = s.model { line += " · \(model)" }
                if let groupID = s.mergeGroupID, let group = try db.group(id: groupID) { line += " · group \"\(group.name)\" #\(s.mergeIndex ?? 0)" }
                line += " · branch \(s.branch)"
                if let report = try db.latestReport(subagentID: s.id) { line += "\n  status: \(report.summary)" }
                if FileManager.default.fileExists(atPath: s.worktreePath) {
                    let files = git.changedFiles(from: s.baseCommit, in: s.worktreePath)
                    if !files.isEmpty { line += "\n  changed_files: \(files.prefix(40).joined(separator: ", "))" }
                }
                return line
            }.joined(separator: "\n")

        case ("main", "message_subagent"):
            let target = try ownSubagent(args["id"], sessionID: sessionID)
            let text = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw RPCError(message: "text is required") }
            guard ![.merged, .discarded, .failed].contains(target.state) else { throw RPCError(message: "subagent #\(target.id) is \(target.state.rawValue)") }
            if hosts[target.id] != nil {
                deliver(target.id, text)
                return "Delivered to #\(target.id)."
            }
            pendingMessages[target.id, default: []].append(text)
            try reopen(target.id, nudge: false)
            return "Reopened #\(target.id) and queued the message."

        case ("main", "set_merge_order"):
            let name = (args["group"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw RPCError(message: "group is required") }
            let ids = (args["ids"] as? [Int] ?? []).map(Int64.init)
            guard !ids.isEmpty else { throw RPCError(message: "ids must not be empty") }
            for raw in ids {
                let s = try ownSubagent(raw, sessionID: sessionID)
                guard s.state != .discarded else { throw RPCError(message: "#\(s.id) was discarded") }
            }
            guard let group = try db.group(sessionID: sessionID, name: name, create: true) else { throw RPCError(message: "could not create group") }
            // Members moving in from another group leave it first.
            for raw in ids {
                let s = try require(raw)
                if let other = s.mergeGroupID, other != group.id {
                    let previous = try db.members(groupID: other)
                    try db.removeFromGroup(raw)
                    try db.applyOrder(groupID: other, MergeOrder.removing(raw, from: previous))
                }
            }
            let order = MergeOrder.reordering(try db.members(groupID: group.id), requested: ids)
            try db.applyOrder(groupID: group.id, order)
            pushSnapshots()
            return "Merge group \"\(name)\": " + order.sorted { $0.value < $1.value }.map { "#\($0.value) → subagent \($0.key)" }.joined(separator: ", ")

        case ("main", "mark_merged"):
            let target = try ownSubagent(args["id"], sessionID: sessionID)
            return try verifyMerge(target.id, mergeCommit: args["merge_commit"] as? String)

        case ("main", "merge_failed"):
            let target = try ownSubagent(args["id"], sessionID: sessionID)
            return try failMerge(target.id, reason: args["reason"] as? String ?? "unspecified")

        case ("subagent", "report_status"):
            guard let agentID else { throw RPCError(message: "report_status is only available to subagents") }
            var s = try require(agentID)
            let summary = (args["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { throw RPCError(message: "summary is required") }
            let done = args["done"] as? [String] ?? []
            let next = args["next"] as? [String] ?? []
            try db.addReport(subagentID: agentID, summary: summary, done: done, next: next)
            s.lastReportTurn = s.turnsStarted
            s.lastReportAt = Date()
            try db.save(s)
            writeStatusFile(s, summary: summary, done: done, next: next)
            pushSnapshots()
            return "Status saved."

        case ("subagent", "mark_complete"):
            guard let agentID else { throw RPCError(message: "mark_complete is only available to subagents") }
            var s = try require(agentID)
            let dirty = git.dirtyFiles(s.worktreePath)
            guard dirty.isEmpty else { throw RPCError(message: "Commit all work first. Uncommitted: \(dirty.prefix(20).joined(separator: ", "))") }
            let summary = (args["summary"] as? String ?? "Complete").trimmingCharacters(in: .whitespacesAndNewlines)
            try db.addReport(subagentID: agentID, summary: summary, done: [summary], next: [])
            s.completedAt = Date()
            s.lastReportTurn = s.turnsStarted
            s.lastReportAt = Date()
            try db.save(s)
            writeStatusFile(s, summary: summary, done: [summary], next: [])
            if s.state == .merging && s.mergeSubstate == .awaitingCommit {
                commitWaitGeneration[agentID, default: 0] += 1
                transition(&s, .commitLanded)
                try deliverMergeRequest(&s)
            } else {
                transition(&s, .markedComplete)
                log(.info, "marked complete: \(summary)", subagent: s)
            }
            pushSnapshots()
            return "Marked complete."

        default:
            throw RPCError(message: "tool \(name) is not available to role \(role)")
        }
    }

    private func ownSubagent(_ raw: Any?, sessionID: Int64) throws -> Subagent {
        guard let value = raw as? Int else { throw RPCError(message: "id must be a subagent number") }
        let s = try require(Int64(value))
        guard s.sessionID == sessionID else { throw RPCError(message: "subagent #\(value) belongs to another session") }
        return s
    }

    func writeStatusFile(_ s: Subagent, summary: String, done: [String], next: [String]) {
        var text = "# #\(s.id) \(s.title)\n\nUpdated \(ISO8601DateFormatter().string(from: Date()))\n\n## Summary\n\(summary)\n"
        if !done.isEmpty { text += "\n## Done\n" + done.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        if !next.isEmpty { text += "\n## Next\n" + next.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        try? text.write(toFile: subagentDirectory(s.id) + "/status.md", atomically: true, encoding: .utf8)
    }

    // MARK: Hooks

    func hook(event: String, payload: [String: Any], agentID: Int64?) -> String {
        guard let agentID, var s = try? db.subagent(id: agentID) else { return "" }
        var reply = HookReply.none
        switch event {
        case "user-prompt-submit":
            s.turnsStarted += 1
            let wasComplete = s.state == .complete
            transition(&s, .promptSubmitted)
            if wasComplete && s.state == .running {
                s.completedAt = nil
                try? db.save(s)
            }
            try? db.setNote(agentID, nil)
        case "post-tool-use":
            transition(&s, .toolUsed)
            reply = HookPolicy.onPostToolUse(s, now: Date())
        case "notification":
            if payload["notification_type"] as? String == "permission_prompt" {
                transition(&s, .permissionPrompt)
            }
        case "stop":
            transition(&s, .turnStopped)
            reply = HookPolicy.onStop(s, stopHookActive: payload["stop_hook_active"] as? Bool ?? false)
        default:
            break
        }
        pushSnapshots()
        return String(data: HookPolicy.stdout(for: reply), encoding: .utf8) ?? ""
    }
}
