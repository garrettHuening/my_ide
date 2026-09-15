import Foundation

/// Index assignment for merge groups (spec §5 "Merge groups"). Every function returns the
/// complete new numbering, 1…n with no gaps, for all non-discarded members. Merged members
/// always stay ahead of unmerged ones.
public enum MergeOrder {
    public static func appending(_ newID: Int64, to members: [Subagent]) -> [Int64: Int] {
        number(ordered(members).map(\.id).filter { $0 != newID } + [newID])
    }

    /// `position` is 1-based over the whole group and is clamped so the new member never
    /// lands before an already merged one.
    public static func inserting(_ newID: Int64, at position: Int, into members: [Subagent]) -> [Int64: Int] {
        let current = ordered(members).filter { $0.id != newID }
        let merged = current.filter { $0.state == .merged }.map(\.id)
        var unmerged = current.filter { $0.state != .merged }.map(\.id)
        let slot = min(max(position - 1 - merged.count, 0), unmerged.count)
        unmerged.insert(newID, at: slot)
        return number(merged + unmerged)
    }

    /// `requested` may include ids not yet in the group (they are being moved in). Merged ids
    /// and duplicates in `requested` are ignored; unmentioned unmerged members keep their
    /// relative order after the requested ones.
    public static func reordering(_ members: [Subagent], requested: [Int64]) -> [Int64: Int] {
        let current = ordered(members)
        let merged = current.filter { $0.state == .merged }.map(\.id)
        let mergedSet = Set(merged)
        var seen = Set<Int64>()
        let front = requested.filter { !mergedSet.contains($0) && seen.insert($0).inserted }
        let rest = current.map(\.id).filter { !mergedSet.contains($0) && !seen.contains($0) }
        return number(merged + front + rest)
    }

    public static func removing(_ id: Int64, from members: [Subagent]) -> [Int64: Int] {
        number(ordered(members).map(\.id).filter { $0 != id })
    }

    private static func ordered(_ members: [Subagent]) -> [Subagent] {
        members
            .filter { $0.state != .discarded }
            .sorted { ($0.mergeIndex ?? Int.max, $0.id) < ($1.mergeIndex ?? Int.max, $1.id) }
    }

    private static func number(_ ids: [Int64]) -> [Int64: Int] {
        Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset + 1) })
    }
}
