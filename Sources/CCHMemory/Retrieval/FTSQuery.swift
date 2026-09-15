import Foundation

/// Builds safe FTS5 MATCH expressions from free text (prompts are arbitrary user input).
public enum FTSQuery {
    private static let stopwords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "your", "with", "this", "that", "have", "has",
        "was", "were", "what", "when", "where", "which", "who", "why", "how", "can", "could", "should",
        "would", "will", "into", "from", "about", "there", "their", "them", "then", "than", "just",
        "like", "some", "any", "all", "our", "out", "its", "it's", "does", "did", "doing", "make",
        "want", "need", "please", "let", "lets", "get", "got", "also", "only", "very", "really", "yeah",
        "okay", "hey", "being", "been", "these", "those", "they", "we're", "i'm", "don't", "use", "using"
    ]

    /// Lowercased ASCII-alphanumeric tokens of length ≥ 3, stopwords removed, order kept, unique.
    public static func tokens(in text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        var current = ""
        func flush() {
            if current.count >= 3, !stopwords.contains(current), seen.insert(current).inserted {
                out.append(current)
            }
            current = ""
        }
        for scalar in text.lowercased().unicodeScalars {
            if scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_") {
                current.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    /// `"tok1" OR "tok2" …` (at most `limit` tokens), or nil when nothing searchable remains.
    public static func match(for text: String, limit: Int = 24) -> String? {
        let toks = tokens(in: text).prefix(limit)
        guard !toks.isEmpty else { return nil }
        return toks.map { "\"\($0)\"" }.joined(separator: " OR ")
    }
}
