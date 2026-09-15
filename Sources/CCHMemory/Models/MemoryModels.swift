import Foundation

public enum MemoryKind: String, CaseIterable, Codable, Sendable {
    case architecture
    case feature
    case api
    case design
    case script
    case diagram
    case doc
    case learning
    case session
    case bugLearning = "bug-learning"

    /// Kinds that dreaming and `memory_update` may never touch.
    public var isFrozen: Bool { self == .bugLearning }
}

/// Where a memory's claim comes from. Code is ground truth about what exists; docs are claims.
public enum MemorySource: String, CaseIterable, Codable, Sendable {
    case code
    case doc
    case session
    case user
}

public enum EdgeRelation: String, CaseIterable, Codable, Sendable {
    case partOf = "part_of"
    case affects
    case documents
    case touchedIn = "touched_in"
    case relatesTo = "relates_to"
}

public enum GroundingStrictness: String, CaseIterable, Codable, Sendable {
    case off
    case balanced
    case strict

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .balanced: return "Balanced"
        case .strict: return "Strict"
        }
    }
}

public struct Project: Equatable, Sendable {
    public let id: Int64
    public let key: String
    public let name: String
    public let root: String
}

public struct Memory: Equatable, Sendable {
    public let id: Int64
    public let projectID: Int64
    public var kind: MemoryKind
    public var title: String
    public var body: String
    public var source: MemorySource
    public var filePointer: String?
    public var branch: String?
    public var sessionID: String?
    public var supersededBy: Int64?
    public var createdAt: Date
    public var updatedAt: Date

    public var citation: String { "M\(id)" }
}

public struct FeatureVersion: Equatable, Sendable {
    public let featureID: Int64
    public let version: Int
    public let description: String
    public let reason: String
    public let createdAt: Date
}

public enum BugStatus: String, Codable, Sendable {
    case open
    case fixed
}

public struct Bug: Equatable, Sendable {
    public let id: Int64
    public let projectID: Int64
    public let number: Int
    public let title: String
    public let symptom: String
    public let featureID: Int64?
    public let featureVersion: Int?
    public let status: BugStatus
    public let rootCause: String?
    public let fixSummary: String?
    public let branch: String?
    public let commitSHA: String?
    public let createdAt: Date
    public let fixedAt: Date?

    public var citation: String { "BUG-\(number)" }
}

public struct MemoryLink: Equatable, Sendable {
    public let fromID: Int64
    public let toID: Int64
    public let relation: EdgeRelation
}
