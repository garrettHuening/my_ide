import Foundation

/// Spots prompts that read like the user correcting Claude's previous answer. Paired with the
/// memories injected for that answer, these are near-miss retrievals worth reviewing later.
public enum CorrectionDetector {
    private static let openers = try! NSRegularExpression(
        pattern: #"^\s*(no|nope|nah|wrong|incorrect|actually|not quite|not really|that'?s (wrong|not right|incorrect|not it|not true)|that is (wrong|not right|incorrect)|you'?re wrong)\b"#,
        options: [.caseInsensitive])
    private static let anywhere = try! NSRegularExpression(
        pattern: #"\b(that'?s not (right|correct|how)|that is not (right|correct|how)|not what i (asked|meant|said)|you misunderstood|doesn'?t exist|that'?s outdated|no longer (true|the case))\b"#,
        options: [.caseInsensitive])

    public static func looksLikeCorrection(_ prompt: String) -> Bool {
        let range = NSRange(prompt.startIndex..., in: prompt)
        return openers.firstMatch(in: prompt, range: range) != nil || anywhere.firstMatch(in: prompt, range: range) != nil
    }
}

extension MemoryStore {
    /// Memory and bug ids injected by the most recent retrieval of a session.
    public func lastRetrieval(sessionID: String) throws -> (memoryIDs: [Int64], bugIDs: [Int64])? {
        try db.queryOne("SELECT memory_ids, bug_ids FROM retrievals WHERE session_id = ? ORDER BY id DESC LIMIT 1", [sessionID]) { row in
            (row.string(0).split(separator: ",").compactMap { Int64($0) }, row.string(1).split(separator: ",").compactMap { Int64($0) })
        }
    }
}

extension ConsoleLog {
    public func domains() throws -> [String] {
        var out: [String] = []
        try db.query("SELECT DISTINCT domain FROM log ORDER BY domain") { out.append($0.string(0)) }
        return out
    }
}
