import Foundation

/// Turns a Claude Code transcript (JSONL) into compact text for summarizing (spec section 3, M5).
public enum TranscriptCondenser {
    public static let toolOutputCharacters = 300
    public static let maxCharacters = 150_000

    public static func condense(jsonl: String) -> String {
        var lines: [String] = []
        for raw in jsonl.split(separator: "\n") {
            guard let data = raw.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = entry["type"] as? String,
                  let message = entry["message"] as? [String: Any] else { continue }
            let content = message["content"]
            switch type {
            case "user":
                if let text = content as? String {
                    lines.append("USER: \(text)")
                } else if let blocks = content as? [[String: Any]] {
                    for block in blocks {
                        switch block["type"] as? String {
                        case "text": lines.append("USER: \(block["text"] as? String ?? "")")
                        case "tool_result": lines.append("  [result] \(truncate(flatten(block["content"]), toolOutputCharacters))")
                        default: break
                        }
                    }
                }
            case "assistant":
                for block in content as? [[String: Any]] ?? [] {
                    switch block["type"] as? String {
                    case "text": lines.append("CLAUDE: \(block["text"] as? String ?? "")")
                    case "tool_use":
                        let input = (block["input"]).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
                            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        lines.append("  [tool \(block["name"] as? String ?? "?")] \(truncate(input, 200))")
                    default: break
                    }
                }
            default:
                continue
            }
        }
        let text = lines.joined(separator: "\n")
        guard text.count > maxCharacters else { return text }
        return "[…earlier conversation omitted…]\n" + String(text.suffix(maxCharacters))
    }

    /// Memory ids (`[M12]`, `M12`) and bug numbers (`BUG-3`) mentioned anywhere in the transcript.
    public static func references(in text: String) -> (memoryIDs: Set<Int64>, bugNumbers: Set<Int>) {
        var memories = Set<Int64>()
        var bugs = Set<Int>()
        let range = NSRange(text.startIndex..., in: text)
        memoryPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            if let r = match.flatMap({ Range($0.range(at: 1), in: text) }), let id = Int64(text[r]) { memories.insert(id) }
        }
        bugPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            if let r = match.flatMap({ Range($0.range(at: 1), in: text) }), let n = Int(text[r]) { bugs.insert(n) }
        }
        return (memories, bugs)
    }

    private static let memoryPattern = try! NSRegularExpression(pattern: #"\[M(\d+)\]"#)
    private static let bugPattern = try! NSRegularExpression(pattern: #"\bBUG-(\d+)\b"#)

    private static func flatten(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: " ")
        }
        return ""
    }

    private static func truncate(_ s: String, _ max: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        return flat.count > max ? String(flat.prefix(max)) + "…" : flat
    }
}

/// Writes or updates the one `session` memory per Claude session.
public enum SessionSnapshot {
    /// Sessions with less condensed text than this aren't worth a summary.
    public static let minimumCharacters = 1_500

    public static func prompt(condensed: String, projectName: String) -> String {
        """
        Summarize this Claude Code session on the project "\(projectName)" so a future session can continue where it left off.

        Reply with markdown only, no preamble:
        - First line: a focus title of at most 8 words (no "Session" prefix, no punctuation at the end).
        - Then these sections, each a few terse bullets: ## Goal, ## Done, ## Decisions (include the why), ## Open threads, ## Next steps.
        - Mention concrete files, symbols, commands, memory ids like [M12] and bugs like BUG-3 when they appear.
        - At most 350 words.

        Transcript:
        \(condensed)
        """
    }

    /// Splits the model reply into (focus, body).
    public static func parse(reply: String) -> (focus: String, body: String)? {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let first = lines.removeFirst().trimmingCharacters(in: CharacterSet(charactersIn: "# *").union(.whitespaces))
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty, !body.isEmpty else { return nil }
        return (String(first.prefix(80)), body)
    }

    public static func title(focus: String, projectName: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "Session \(formatter.string(from: date)) · \(projectName) · \(focus)"
    }

    /// Saves the summary and links it to everything the session touched. Returns the memory.
    @discardableResult
    public static func save(store: MemoryStore, projectID: Int64, sessionID: String, projectName: String,
                            reply: String, transcript: String, branch: String?, date: Date = Date()) throws -> Memory? {
        guard let parsed = parse(reply: reply) else { return nil }
        let title = title(focus: parsed.focus, projectName: projectName, date: date)
        let memory: Memory
        if let existing = try store.sessionMemory(sessionID: sessionID) {
            memory = try store.updateMemory(id: existing.id, title: title, body: parsed.body)
        } else {
            memory = try store.writeMemory(projectID: projectID, kind: .session, title: title, body: parsed.body,
                                           source: .session, branch: branch, sessionID: sessionID).memory
        }
        let refs = TranscriptCondenser.references(in: transcript)
        let touched = refs.memoryIDs.union(try store.retrievedMemoryIDs(sessionID: sessionID))
        for (id, other) in try store.memories(ids: Array(touched)) where id != memory.id && other.projectID == projectID {
            try store.link(from: memory.id, to: id, relation: .touchedIn)
        }
        return memory
    }
}

extension MemoryStore {
    public func sessionMemory(sessionID: String) throws -> Memory? {
        try db.queryOne("SELECT \(Self.memoryColumns) FROM memories WHERE kind = 'session' AND session_id = ? AND superseded_by IS NULL LIMIT 1",
                        [sessionID], map: Self.memory)
    }

    public func retrievedMemoryIDs(sessionID: String) throws -> Set<Int64> {
        var out = Set<Int64>()
        try db.query("SELECT memory_ids FROM retrievals WHERE session_id = ?", [sessionID]) { row in
            for part in row.string(0).split(separator: ",") {
                if let id = Int64(part) { out.insert(id) }
            }
        }
        return out
    }
}
