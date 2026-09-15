import Foundation

/// MCP tool definitions for subagent orchestration. cch-mcp lists them and forwards calls to
/// cch-agentd, which implements them.
public enum SubagentTools {
    public enum Role: String, Sendable {
        case main
        case subagent
    }

    public static func definitions(for role: Role) -> [[String: Any]] {
        switch role {
        case .main:
            return [
                tool("spawn_subagent", "Start a subagent in its own git worktree based on this session's current commit. Use for /task, /bugfix, /feature, /helper.",
                     properties: [
                        "category": ["type": "string", "enum": SubagentCategory.allCases.map(\.rawValue)],
                        "title": ["type": "string", "description": "At most 6 words."],
                        "brief": ["type": "string", "description": "Self-contained brief: goal, context, likely files, acceptance criteria, constraints, how to verify."],
                        "merge_group": ["type": "string", "description": "Name of a merge group when this work overlaps with other subagents and merge order matters."],
                        "merge_index": ["type": "integer", "minimum": 1, "description": "Position in the merge group (default: after existing members)."],
                        "model": ["type": "string", "description": "Only when the user explicitly named a model: fable, opus, sonnet, haiku or a full claude-… name."]
                     ], required: ["category", "title", "brief"]),
                tool("list_subagents", "List this session's subagents with state, merge order, last status and changed files.",
                     properties: [:], required: []),
                tool("message_subagent", "Send a message to a subagent (reopens it if it isn't running).",
                     properties: ["id": ["type": "integer"], "text": ["type": "string"]], required: ["id", "text"]),
                tool("set_merge_order", "Create or reorder a merge group: subagent ids in the order they must be merged.",
                     properties: ["group": ["type": "string"], "ids": ["type": "array", "items": ["type": "integer"]]], required: ["group", "ids"]),
                tool("mark_merged", "Report that you merged a subagent's branch (after a merge request).",
                     properties: ["id": ["type": "integer"], "merge_commit": ["type": "string"]], required: ["id"]),
                tool("merge_failed", "Report that a merge request could not be completed.",
                     properties: ["id": ["type": "integer"], "reason": ["type": "string"]], required: ["id", "reason"])
            ]
        case .subagent:
            return [
                tool("report_status", "Save your progress so work can resume after a crash. Call after each meaningful step and before ending a turn.",
                     properties: [
                        "summary": ["type": "string"],
                        "done": ["type": "array", "items": ["type": "string"]],
                        "next": ["type": "array", "items": ["type": "string"]]
                     ], required: ["summary"]),
                tool("mark_complete", "Mark your brief complete. Everything must be committed first.",
                     properties: ["summary": ["type": "string"]], required: ["summary"])
            ]
        }
    }

    public static func names(for role: Role) -> Set<String> {
        Set(definitions(for: role).compactMap { $0["name"] as? String })
    }

    private static func tool(_ name: String, _ description: String, properties: [String: Any], required: [String]) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required]]
    }
}

/// What the app shows for a subagent row.
public struct SubagentSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: Int64
    public let sessionID: Int64
    public let category: String
    public let title: String
    public let model: String?
    public let state: String
    public let mergeSubstate: String?
    public let branch: String
    public let worktreePath: String
    public let mergeGroupID: Int64?
    public let mergeGroupName: String?
    public let mergeIndex: Int?
    public let lastStatus: String?
    public let lastStatusAt: Date?
    public let note: String?
    public let hidden: Bool
    public let hasCommits: Bool
    public let isDirty: Bool
    public let hostAlive: Bool
    public let createdAt: Date

    public init(subagent s: Subagent, groupName: String?, report: StatusReport?, note: String?, hidden: Bool,
                hasCommits: Bool, isDirty: Bool, hostAlive: Bool) {
        id = s.id
        sessionID = s.sessionID
        category = s.category.rawValue
        title = s.title
        model = s.model
        state = s.state.rawValue
        mergeSubstate = s.mergeSubstate?.rawValue
        branch = s.branch
        worktreePath = s.worktreePath
        mergeGroupID = s.mergeGroupID
        mergeGroupName = groupName
        mergeIndex = s.mergeIndex
        lastStatus = report?.summary
        lastStatusAt = report?.at
        self.note = note
        self.hidden = hidden
        self.hasCommits = hasCommits
        self.isDirty = isDirty
        self.hostAlive = hostAlive
        createdAt = s.createdAt
    }

    public var subagentCategory: SubagentCategory { SubagentCategory(rawValue: category) ?? .task }
    public var subagentState: SubagentState { SubagentState(rawValue: state) ?? .failed }
    public var subagentMergeSubstate: MergeSubstate? { mergeSubstate.flatMap(MergeSubstate.init(rawValue:)) }

    /// A Subagent value carrying just what `MergeGate` needs.
    public var gateSubagent: Subagent {
        Subagent(id: id, sessionID: sessionID, category: subagentCategory, title: title, state: subagentState,
                 mergeSubstate: subagentMergeSubstate, mergeGroupID: mergeGroupID, mergeIndex: mergeIndex, createdAt: createdAt)
    }

    public static func encode(_ list: [SubagentSnapshot]) -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(list) else { return [] }
        return (try? JSONSerialization.jsonObject(with: data)) ?? []
    }

    public static func decode(_ object: Any) -> [SubagentSnapshot] {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([SubagentSnapshot].self, from: data)) ?? []
    }
}
