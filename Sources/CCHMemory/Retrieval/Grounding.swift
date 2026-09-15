import Foundation

/// Grounding rules and the text block injected ahead of every prompt (spec section 2).
public enum Grounding {
    /// Strict needs enough memories to cite; below this a project is treated as Balanced.
    public static let strictMinimumMemories = 50
    public static let strictMinimumAnswerCharacters = 400
    public static let excerptCount = 3
    public static let excerptCharacters = 600
    public static let characterBudget = 6000

    public static func effective(_ strictness: GroundingStrictness, memoryCount: Int) -> GroundingStrictness {
        strictness == .strict && memoryCount < strictMinimumMemories ? .balanced : strictness
    }

    public static func rules(for strictness: GroundingStrictness, toolPrefix: String) -> String? {
        switch strictness {
        case .off:
            return nil
        case .balanced:
            return """
            Rules: When you state facts about this project's APIs, architecture, features or past bugs, cite the memory you rely on, e.g. [M12] or [BUG-3]. If no memory supports a claim, say it is unverified or check the code. If a doc-sourced memory and a code-sourced memory disagree, trust the code, tell the user, and call \(toolPrefix)memory_flag_conflict. When you learn something durable about this project (API behavior, a design reason, a gotcha, a fix), record it with \(toolPrefix)memory_write.
            """
        case .strict:
            return """
            Rules (strict): Every project-specific claim must cite a memory, e.g. [M12] or [BUG-3]. If no memory supports it, either ask the user or read the code and record what you verified with \(toolPrefix)memory_write before answering. If a doc-sourced memory and a code-sourced memory disagree, trust the code, tell the user, and call \(toolPrefix)memory_flag_conflict. Record durable learnings with \(toolPrefix)memory_write.
            """
        }
    }

    /// The `<core-memories>` block, or nil when there is nothing to inject.
    public static func contextBlock(items: [RetrievedItem], projectName: String, strictness: GroundingStrictness,
                                    featureVersions: [Int64: Int], toolPrefix: String) -> String? {
        let rules = rules(for: strictness, toolPrefix: toolPrefix)
        guard !items.isEmpty else { return nil }

        var lines: [String] = []
        var used = 0
        for (index, item) in items.enumerated() {
            var entry = line(for: item, featureVersions: featureVersions)
            if index < excerptCount || item.pinned, let excerpt = excerpt(for: item) {
                entry += "\n  excerpt: \"\(excerpt)\""
            }
            if used + entry.count > characterBudget && !lines.isEmpty { break }
            used += entry.count
            lines.append(entry)
        }

        var block = "<core-memories project=\"\(escape(projectName))\" strictness=\"\(strictness.rawValue)\" count=\"\(lines.count)\">\n"
        block += lines.joined(separator: "\n")
        if let rules { block += "\n" + rules }
        block += "\nFull text: \(toolPrefix)memory_get(id). Search more: \(toolPrefix)memory_search(query)."
        block += "\n</core-memories>"
        return block
    }

    static func line(for item: RetrievedItem, featureVersions: [Int64: Int]) -> String {
        let marker = item.pinned ? " (previous session)" : item.viaLink ? " (linked)" : ""
        switch item.ref {
        case .memory(let m):
            var kind = m.kind.rawValue
            if m.kind == .feature, let v = featureVersions[m.id] { kind += " v\(v)" }
            return "[M\(m.id)] \(kind) · \(m.source.rawValue) · \(oneLine(m.title))\(marker) — \(oneLine(m.body, max: 140))"
        case .bug(let b):
            let against = b.featureID.map { fid in " against M\(fid)" + (b.featureVersion.map { " v\($0)" } ?? "") } ?? ""
            let summary = b.status == .fixed ? (b.fixSummary ?? b.symptom) : b.symptom
            return "[BUG-\(b.number)] \(b.status.rawValue)\(against) · \(oneLine(b.title))\(marker) — \(oneLine(summary, max: 140))"
        }
    }

    static func excerpt(for item: RetrievedItem) -> String? {
        switch item.ref {
        case .memory(let m):
            return m.body.count > 140 ? oneLine(m.body, max: excerptCharacters) : nil
        case .bug(let b):
            guard b.status == .fixed, let cause = b.rootCause else { return nil }
            return oneLine("Root cause: \(cause)", max: excerptCharacters)
        }
    }

    public static func oneLine(_ text: String, max: Int = 200) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "'")
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "'")
    }

    // MARK: Strict stop check

    private static let citationPattern = try! NSRegularExpression(pattern: #"\[(M\d+|BUG-\d+)\]"#)

    public static func hasCitation(_ text: String) -> Bool {
        citationPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Reason to block a Stop in strict mode, or nil to allow it.
    public static func strictStopReason(strictness: GroundingStrictness, stopHookActive: Bool,
                                        assistantText: String, retrievedCount: Int) -> String? {
        guard strictness == .strict, !stopHookActive, retrievedCount > 0,
              assistantText.count > strictMinimumAnswerCharacters, !hasCitation(assistantText) else { return nil }
        return "Strict grounding is on and core memories were provided, but your answer cites none. Revise it to cite the memories you relied on ([M12], [BUG-3]), or state clearly which claims are unverified."
    }
}
