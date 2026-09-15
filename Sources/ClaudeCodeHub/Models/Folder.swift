import Foundation

struct Folder: Identifiable, Hashable {
    var id: Int64
    var name: String
    var sortOrder: Double
    var expanded: Bool
    var createdAt: Date
    var updatedAt: Date
}
