import Foundation

/// One row of agents.db `subagents` (spec §2).
public struct Subagent: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var sessionID: Int64
    public var sessionDir: String
    public var repoRoot: String
    public var category: SubagentCategory
    public var title: String
    public var brief: String
    public var model: String?
    public var state: SubagentState
    public var mergeSubstate: MergeSubstate?
    public var claudeSessionID: String
    public var worktreePath: String
    public var branch: String
    public var baseCommit: String
    public var baseBranch: String?
    public var mergeTip: String?
    public var mergeGroupID: Int64?
    public var mergeIndex: Int?
    public var hostPID: Int32?
    public var hostStartedAt: Date?
    public var resumeCount: Int
    public var lastResumeAt: Date?
    public var turnsStarted: Int
    public var lastReportTurn: Int
    public var lastReportAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var mergedAt: Date?
    public var failureReason: String?

    public init(
        id: Int64,
        sessionID: Int64,
        sessionDir: String = "",
        repoRoot: String = "",
        category: SubagentCategory,
        title: String,
        brief: String = "",
        model: String? = nil,
        state: SubagentState = .starting,
        mergeSubstate: MergeSubstate? = nil,
        claudeSessionID: String = "",
        worktreePath: String = "",
        branch: String = "",
        baseCommit: String = "",
        baseBranch: String? = nil,
        mergeTip: String? = nil,
        mergeGroupID: Int64? = nil,
        mergeIndex: Int? = nil,
        hostPID: Int32? = nil,
        hostStartedAt: Date? = nil,
        resumeCount: Int = 0,
        lastResumeAt: Date? = nil,
        turnsStarted: Int = 0,
        lastReportTurn: Int = -1,
        lastReportAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil,
        mergedAt: Date? = nil,
        failureReason: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sessionDir = sessionDir
        self.repoRoot = repoRoot
        self.category = category
        self.title = title
        self.brief = brief
        self.model = model
        self.state = state
        self.mergeSubstate = mergeSubstate
        self.claudeSessionID = claudeSessionID
        self.worktreePath = worktreePath
        self.branch = branch
        self.baseCommit = baseCommit
        self.baseBranch = baseBranch
        self.mergeTip = mergeTip
        self.mergeGroupID = mergeGroupID
        self.mergeIndex = mergeIndex
        self.hostPID = hostPID
        self.hostStartedAt = hostStartedAt
        self.resumeCount = resumeCount
        self.lastResumeAt = lastResumeAt
        self.turnsStarted = turnsStarted
        self.lastReportTurn = lastReportTurn
        self.lastReportAt = lastReportAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.mergedAt = mergedAt
        self.failureReason = failureReason
    }

    public var phase: SubagentPhase {
        get { SubagentPhase(state, mergeSubstate) }
        set {
            state = newValue.state
            mergeSubstate = newValue.substate
        }
    }
}
