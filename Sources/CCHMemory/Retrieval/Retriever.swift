import Foundation

public enum RetrievedRef: Equatable, Sendable {
    case memory(Memory)
    case bug(Bug)

    public var key: String {
        switch self {
        case .memory(let m): return "M\(m.id)"
        case .bug(let b): return "B\(b.id)"
        }
    }
}

public struct RetrievedItem: Equatable, Sendable {
    public let ref: RetrievedRef
    public let score: Double
    /// Pulled in through a graph link rather than matched directly.
    public let viaLink: Bool
    /// Always-included previous-session memory.
    public let pinned: Bool
}

public struct RetrievalConfig: Sendable {
    public var candidateLimit = 40
    public var seedCount = 8
    public var maxEntries = 12
    public var minPromptCharacters = 12
    public var linkedScoreFactor = 0.5
    public var bugSimilarityThreshold: Float = 0.35
    public var recentBugsPerFeature = 3
    public var rrfK = 60.0

    public init() {}
}

/// Hybrid retrieval (spec section 2): keyword + embedding candidates fused with reciprocal rank
/// fusion, then expanded one hop through the memory graph.
public final class Retriever {
    public let store: MemoryStore
    public var config: RetrievalConfig

    public init(store: MemoryStore, config: RetrievalConfig = RetrievalConfig()) {
        self.store = store
        self.config = config
    }

    /// `projectIDs == nil` searches every project.
    public func retrieve(prompt: String, projectIDs: [Int64]?, includeSessionMemoryFor projectID: Int64? = nil,
                         limit: Int? = nil) throws -> [RetrievedItem] {
        let limit = limit ?? config.maxEntries
        var pinned: [RetrievedItem] = []
        if let projectID, let session = try store.latestSessionMemory(projectID: projectID) {
            pinned.append(RetrievedItem(ref: .memory(session), score: .infinity, viaLink: false, pinned: true))
        }

        guard prompt.trimmingCharacters(in: .whitespacesAndNewlines).count >= config.minPromptCharacters else {
            return pinned
        }

        let match = FTSQuery.match(for: prompt)
        let vector = store.embedder?.embed(prompt)

        var memoryLists: [[Int64]] = []
        var bugLists: [[Int64]] = []
        if let match {
            memoryLists.append(try store.ftsMemories(projectIDs: projectIDs, match: match, limit: config.candidateLimit))
            bugLists.append(try store.ftsBugs(projectIDs: projectIDs, match: match, limit: config.candidateLimit / 2))
        }
        if let vector {
            memoryLists.append(try store.vectorMemories(projectIDs: projectIDs, vector: vector, limit: config.candidateLimit).map(\.id))
            bugLists.append(try store.vectorBugs(projectIDs: projectIDs, vector: vector, limit: config.candidateLimit / 2).map(\.id))
        }

        let memoryScores = Self.reciprocalRankFusion(memoryLists, k: config.rrfK)
        let bugScores = Self.reciprocalRankFusion(bugLists, k: config.rrfK)

        var scores: [String: (ref: RetrievedRef, score: Double, viaLink: Bool)] = [:]
        let memoryMap = try store.memories(ids: Array(memoryScores.keys))
        for (id, score) in memoryScores {
            if let m = memoryMap[id] { scores["M\(id)"] = (.memory(m), score, false) }
        }
        let bugMap = try store.bugs(ids: Array(bugScores.keys))
        for (id, score) in bugScores {
            if let b = bugMap[id] { scores["B\(id)"] = (.bug(b), score, false) }
        }

        // One-hop graph expansion from the best direct memory matches.
        let seeds = memoryScores.sorted { $0.value > $1.value }.prefix(config.seedCount)
        for (seedID, seedScore) in seeds {
            let linkedScore = seedScore * config.linkedScoreFactor
            let neighborIDs = try store.links(of: seedID).map { $0.fromID == seedID ? $0.toID : $0.fromID }
            for (nid, neighbor) in try store.memories(ids: neighborIDs) where neighbor.supersededBy == nil {
                if projectIDs.map({ $0.contains(neighbor.projectID) }) == false { continue }
                Self.offer(&scores, key: "M\(nid)", ref: .memory(neighbor), score: linkedScore, viaLink: true)
            }
            guard let seed = memoryMap[seedID], seed.kind == .feature else { continue }
            for (index, bug) in try store.bugs(featureID: seedID).enumerated() {
                let similar = try vector.flatMap { try store.bugSimilarity(bugID: bug.id, to: $0) } ?? 0
                if index < config.recentBugsPerFeature || similar >= config.bugSimilarityThreshold {
                    Self.offer(&scores, key: "B\(bug.id)", ref: .bug(bug), score: linkedScore, viaLink: true)
                }
            }
        }

        let pinnedKeys = Set(pinned.map(\.ref.key))
        let ranked = scores.values
            .filter { !pinnedKeys.contains($0.ref.key) }
            .sorted { lhs, rhs in lhs.score != rhs.score ? lhs.score > rhs.score : lhs.ref.key < rhs.ref.key }
            .prefix(max(limit - pinned.count, 0))
            .map { RetrievedItem(ref: $0.ref, score: $0.score, viaLink: $0.viaLink, pinned: false) }
        return pinned + ranked
    }

    /// Σ 1 / (k + rank), rank starting at 1. Robust to score scales that don't compare (BM25 vs cosine).
    public static func reciprocalRankFusion(_ lists: [[Int64]], k: Double = 60) -> [Int64: Double] {
        var scores: [Int64: Double] = [:]
        for list in lists {
            for (index, id) in list.enumerated() {
                scores[id, default: 0] += 1.0 / (k + Double(index + 1))
            }
        }
        return scores
    }

    private static func offer(_ scores: inout [String: (ref: RetrievedRef, score: Double, viaLink: Bool)],
                              key: String, ref: RetrievedRef, score: Double, viaLink: Bool) {
        if let existing = scores[key] {
            scores[key] = (existing.ref, existing.score + score, existing.viaLink)
        } else {
            scores[key] = (ref, score, viaLink)
        }
    }
}
