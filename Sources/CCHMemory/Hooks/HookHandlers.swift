import Foundation

/// Claude Code hook entry points. Each returns the exact stdout the hook command should print
/// (empty string = print nothing). They never throw: a memory problem must not block a prompt.
public enum HookHandlers {
    public static func userPromptSubmit(payload: [String: Any], store: MemoryStore, console: ConsoleLog?) -> String {
        let prompt = payload["prompt"] as? String ?? ""
        let sessionID = payload["session_id"] as? String
        let cwd = payload["cwd"] as? String ?? FileManager.default.currentDirectoryPath
        do {
            let resolved = ProjectKey.resolve(directory: cwd)
            let project = try store.project(for: resolved)
            let firstPrompt = try sessionID.map { try !store.hasRetrievals(sessionID: $0) } ?? false
            if let sessionID, !firstPrompt, CorrectionDetector.looksLikeCorrection(prompt),
               let previous = try store.lastRetrieval(sessionID: sessionID),
               !(previous.memoryIDs.isEmpty && previous.bugIDs.isEmpty) {
                let ids = previous.memoryIDs.map { "M\($0)" } + previous.bugIDs.map { "bug#\($0)" }
                try? console?.append(domain: "memory.nearmiss", severity: .info, source: "hook:UserPromptSubmit",
                                     message: "Possible near-miss: user corrected an answer grounded in \(ids.joined(separator: ", "))",
                                     projectID: project.id, sessionID: sessionID,
                                     dataJSON: json(["prompt": String(prompt.prefix(300)), "memories": ids]))
            }
            let items = try Retriever(store: store)
                .retrieve(prompt: prompt, projectIDs: [project.id], includeSessionMemoryFor: firstPrompt ? project.id : nil)
            let count = try store.activeMemoryCount(projectID: project.id)
            let strictness = Grounding.effective(try store.strictness(), memoryCount: count)

            try store.logRetrieval(projectID: project.id, sessionID: sessionID, prompt: prompt,
                                   memoryIDs: items.compactMap { if case .memory(let m) = $0.ref { return m.id } else { return nil } },
                                   bugIDs: items.compactMap { if case .bug(let b) = $0.ref { return b.id } else { return nil } })

            let context: String?
            if items.isEmpty {
                context = firstPrompt && strictness != .off
                    ? "<core-memories project=\"\(project.name)\" count=\"0\">\nNo core memories match yet. When you learn something durable about this project, record it with \(MemoryTools.toolPrefix)memory_write; track bugs with \(MemoryTools.toolPrefix)bug_open.\n</core-memories>"
                    : nil
            } else {
                context = Grounding.contextBlock(items: items, projectName: project.name, strictness: strictness,
                                                 featureVersions: try MemoryTools.featureVersions(for: items, store: store),
                                                 toolPrefix: MemoryTools.toolPrefix)
            }
            guard let context else { return "" }
            return json(["hookSpecificOutput": ["hookEventName": "UserPromptSubmit", "additionalContext": context]])
        } catch {
            try? console?.append(domain: "memory", severity: .error, source: "hook:UserPromptSubmit",
                                 message: "retrieval failed: \(error)", sessionID: sessionID)
            return ""
        }
    }

    public static func stop(payload: [String: Any], store: MemoryStore, console: ConsoleLog?) -> String {
        guard let sessionID = payload["session_id"] as? String else { return "" }
        let stopHookActive = payload["stop_hook_active"] as? Bool ?? false
        do {
            let cwd = payload["cwd"] as? String ?? FileManager.default.currentDirectoryPath
            let project = try store.project(for: ProjectKey.resolve(directory: cwd))
            let strictness = Grounding.effective(try store.strictness(), memoryCount: try store.activeMemoryCount(projectID: project.id))
            guard strictness == .strict, let path = payload["transcript_path"] as? String else { return "" }
            let reason = Grounding.strictStopReason(strictness: strictness, stopHookActive: stopHookActive,
                                                    assistantText: lastAssistantText(transcriptPath: path),
                                                    retrievedCount: try store.lastRetrievalCount(sessionID: sessionID))
            guard let reason else { return "" }
            try? console?.append(domain: "memory.grounding", severity: .info, source: "hook:Stop",
                                 message: "blocked an uncited answer (strict)", projectID: project.id, sessionID: sessionID)
            return json(["decision": "block", "reason": reason])
        } catch {
            try? console?.append(domain: "memory", severity: .error, source: "hook:Stop", message: "stop check failed: \(error)", sessionID: sessionID)
            return ""
        }
    }

    /// Assistant text written since the last real user prompt in a Claude Code transcript (JSONL).
    public static func lastAssistantText(transcriptPath: String) -> String {
        guard let contents = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else { return "" }
        var parts: [String] = []
        for line in contents.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = entry["type"] as? String,
                  let message = entry["message"] as? [String: Any] else { continue }
            let content = message["content"]
            if type == "user" {
                if content is String { break }
                if let blocks = content as? [[String: Any]], blocks.contains(where: { $0["type"] as? String == "text" }) { break }
                continue
            }
            guard type == "assistant", let blocks = content as? [[String: Any]] else { continue }
            let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            if !text.isEmpty { parts.insert(text, at: 0) }
        }
        return parts.joined(separator: "\n")
    }

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
