import Foundation

/// The four kinds of subagent. Raw values are stored in agents.db.
public enum SubagentCategory: String, CaseIterable, Codable, Sendable {
    case task
    case bug
    case feature
    case helper

    /// Slash command that spawns this category, without the leading slash.
    /// `bug` ships as `bugfix` because Claude Code has a built-in `/bug`.
    public var commandName: String {
        switch self {
        case .task: return "task"
        case .bug: return "bugfix"
        case .feature: return "feature"
        case .helper: return "helper"
        }
    }

    /// Section header and filter chip label.
    public var displayName: String {
        switch self {
        case .task: return "Task"
        case .bug: return "Bug"
        case .feature: return "Feature"
        case .helper: return "Helper"
        }
    }

    public init?(commandName: String) {
        guard let match = Self.allCases.first(where: { $0.commandName == commandName }) else { return nil }
        self = match
    }
}
