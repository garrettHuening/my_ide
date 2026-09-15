import Foundation
import SwiftUI
import Combine

final class AppState: ObservableObject {
    let db: Database
    let sessions: SessionStore
    let prefs: PrefsStore
    let importer: SessionImporter
    let folders: FolderStore

    enum SidebarTab: String, CaseIterable, Identifiable {
        case sessions = "Sessions"
        case mcps = "MCPs"
        case agents = "Agents"
        case skills = "Skills"
        var id: String { rawValue }
    }

    @Published var sidebarTab: SidebarTab = .sessions
    @Published var showNewSessionModal: Bool = false
    @Published var showSettings: Bool = false
    @Published var rightPanelVisible: Bool = true

    init(db: Database, sessions: SessionStore, prefs: PrefsStore, importer: SessionImporter, folders: FolderStore) {
        self.db = db
        self.sessions = sessions
        self.prefs = prefs
        self.importer = importer
        self.folders = folders
    }
}
