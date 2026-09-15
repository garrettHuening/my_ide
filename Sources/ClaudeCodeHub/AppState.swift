import Foundation
import SwiftUI
import Combine

final class AppState: ObservableObject {
    let db: Database
    let sessions: SessionStore
    let prefs: PrefsStore
    let importer: SessionImporter
    let folders: FolderStore

    /// Subagent shown in the main pane, per session. Missing = the session's main terminal.
    @Published var selectedSubagent: [Int64: Int64] = [:]
    @Published var showNewSessionModal: Bool = false
    @Published var showSettings: Bool = false
    @Published var rightPanelVisible: Bool = true
    @Published var consoleVisible: Bool = false

    init(db: Database, sessions: SessionStore, prefs: PrefsStore, importer: SessionImporter, folders: FolderStore) {
        self.db = db
        self.sessions = sessions
        self.prefs = prefs
        self.importer = importer
        self.folders = folders
    }
}
