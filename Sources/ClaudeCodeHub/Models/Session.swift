import Foundation

enum SessionStatus: String, Codable {
    case running
    case paused
    case stopped
}

enum SessionSource: String, Codable {
    case manual
    case imported
}

struct Session: Identifiable, Hashable {
    var id: Int64
    var name: String
    var workingDir: String
    var tagsRaw: String      // comma-separated; UI splits/joins
    var agentFile: String?
    var initialPrompt: String?
    var status: SessionStatus
    var createdAt: Date
    var updatedAt: Date
    var lastOpenedAt: Date?
    var folderID: Int64?
    var sortOrder: Double
    var hasPendingAction: Bool
    var source: SessionSource
    var missing: Bool
    var importedFrom: String?
    var isFavorite: Bool = false

    var tags: [String] {
        tagsRaw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func tagsString(_ tags: [String]) -> String {
        tags.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ",")
    }

    /// Display-friendly age, e.g. "5m", "2h", "3d".
    var ageString: String {
        let interval = Date().timeIntervalSince(updatedAt)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86_400 { return "\(Int(interval / 3600))h" }
        return "\(Int(interval / 86_400))d"
    }
}
