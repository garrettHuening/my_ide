import SwiftUI
import AppKit

// Without an .app bundle + Info.plist, NSApplication defaults to .prohibited
// activation policy. The bundle wrapper handles that for distribution, but we
// also force the policy here so direct binary launches behave the same.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Diagnose window state at several intervals after launch.
        for delay in [0.05, 0.2, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                appLog("[Window] +\(delay)s windows=\(NSApp.windows.count)")
                for (i, w) in NSApp.windows.enumerated() {
                    appLog("[Window]   #\(i) title=\(w.title) frame=\(w.frame) onScreen=\(w.isOnActiveSpace) visible=\(w.isVisible)")
                }
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.canBecomeKey }) {
                    window.setFrame(NSRect(x: 200, y: 200, width: 1400, height: 880), display: true)
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ClaudeCodeHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var appState: AppState

    init() {
        let db = try! Database.shared()
        let sessions = SessionStore(db: db)
        let prefs = PrefsStore(db: db)
        let importer = SessionImporter(prefs: prefs, sessions: sessions)
        let folders = FolderStore(db: db)
        let state = AppState(db: db, sessions: sessions, prefs: prefs, importer: importer, folders: folders)
        _appState = StateObject(wrappedValue: state)
        TerminalRegistry.shared.bind(sessionStore: sessions)
        // On fresh launch nothing is running yet; clear any stale 'running' rows
        // from prior crashes so dots reflect reality.
        sessions.markAllStopped()
        appLog("[App] launch")
        _ = importer.scan()
        MemoryJobs.shared.startDreamScheduler()
        SubagentsClient.shared.start(app: state)
    }

    var body: some Scene {
        WindowGroup("Claude Code Hub") {
            ContentView()
                .environmentObject(appState)
                .environmentObject(appState.sessions)
                .environmentObject(appState.prefs)
                .environmentObject(appState.importer)
                .environmentObject(appState.folders)
                .frame(minWidth: 1100, minHeight: 700)
                .preferredColorScheme(.dark)
                .background(Theme.bg1)
        }
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1400, height: 880)
        .commands {
            CommandGroup(after: .sidebar) {
                Button(appState.consoleVisible ? "Hide Console" : "Show Console") {
                    appState.consoleVisible.toggle()
                }
                .keyboardShortcut("y", modifiers: [.command, .shift])
            }
        }
    }
}
