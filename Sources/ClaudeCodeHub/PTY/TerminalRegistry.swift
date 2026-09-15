import Foundation
import AppKit
import SwiftTerm
import Combine
import CCHMemory

/// One terminal per session, kept alive across UI swaps so the PTY (and Claude
/// process running in it) doesn't die when the user navigates away. The actual
/// NSView is the cached one — `TerminalHost` re-parents it into the current
/// container instead of creating a new view.
final class TerminalRegistry: ObservableObject {
    static let shared = TerminalRegistry()

    private var terminals: [Int64: LocalProcessTerminalView] = [:]
    private var delegates: [Int64: TerminalDelegate] = [:]
    private weak var sessionStore: SessionStore?

    func bind(sessionStore: SessionStore) {
        self.sessionStore = sessionStore
    }

    func terminal(for session: Session) -> LocalProcessTerminalView {
        if let cached = terminals[session.id] { return cached }
        let term = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        configureAppearance(term)
        let delegate = TerminalDelegate(
            sessionID: session.id,
            onExit: { [weak self] _ in
                self?.sessionStore?.setStatus(session.id, .stopped)
            }
        )
        term.processDelegate = delegate
        delegates[session.id] = delegate
        terminals[session.id] = term
        startProcess(for: session, in: term)
        sessionStore?.setStatus(session.id, .running)
        return term
    }

    func terminate(sessionID: Int64) {
        if let term = terminals[sessionID] {
            term.process.terminate()
        }
        terminals.removeValue(forKey: sessionID)
        delegates.removeValue(forKey: sessionID)
        sessionStore?.setStatus(sessionID, .stopped)
    }

    func isRunning(_ sessionID: Int64) -> Bool {
        terminals[sessionID] != nil
    }

    /// Types a whole message into Claude as a bracketed paste, then presses Enter.
    func sendMessage(_ text: String, to sessionID: Int64) {
        sendInput("\u{1b}[200~" + text + "\u{1b}[201~", to: sessionID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.sendInput("\r", to: sessionID) }
    }

    func sendInput(_ text: String, to sessionID: Int64) {
        guard let term = terminals[sessionID] else { return }
        let bytes: ArraySlice<UInt8> = ArraySlice(Array(text.utf8))
        term.send(data: bytes)
    }

    // MARK: - Private

    private func configureAppearance(_ term: LocalProcessTerminalView) {
        term.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        if let nativeForeground = NSColor(named: "TerminalForeground") {
            term.nativeForegroundColor = nativeForeground
        }
        if let nativeBackground = NSColor(named: "TerminalBackground") {
            term.nativeBackgroundColor = nativeBackground
        }
        // Solid black background matches Theme.bgT
        term.nativeBackgroundColor = NSColor.black
        term.nativeForegroundColor = NSColor(white: 0.96, alpha: 1.0)
    }

    private func startProcess(for session: Session, in term: LocalProcessTerminalView) {
        // Validate working_dir exists; if not, fall back to home.
        let cwd: String = {
            if FileManager.default.fileExists(atPath: session.workingDir) { return session.workingDir }
            appLog("[TerminalRegistry] working_dir missing, falling back to home: \(session.workingDir)")
            return NSHomeDirectory()
        }()

        // Inject permission settings before claude spawns — order matters.
        ClaudeSettings.ensureWritten(at: cwd)

        if let claudePath = ClaudeLocator.findExecutable() {
            let hub = HubPlugin.launchConfiguration(sessionID: session.id, workingDir: cwd, sessions: sessionStore)
            appLog("[TerminalRegistry] spawn claude=\(claudePath) cwd=\(cwd) sid=\(session.id) plugin=\(hub.args.isEmpty ? "missing" : "cch-main")")
            term.startProcess(
                executable: claudePath,
                args: hub.args,
                environment: ClaudeLocator.env() + hub.environment,
                execName: "claude",
                currentDirectory: cwd
            )
            MemoryJobs.shared.sweepIfNeeded(workingDir: cwd)
        } else {
            // Fallback: spawn a shell so the user at least gets a terminal and
            // can see what's wrong.
            appLog("[TerminalRegistry] claude not found on disk; spawning $SHELL in \(cwd)")
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            term.feed(text: "\r\n\u{1b}[31m[Claude Code Hub] claude executable not found.\u{1b}[0m\r\n")
            term.feed(text: "Tried ~/.local/bin/claude and PATH. Falling back to \(shell).\r\n\r\n")
            term.startProcess(
                executable: shell,
                args: ["-l"],
                environment: ClaudeLocator.env(),
                execName: shell,
                currentDirectory: cwd
            )
        }
    }
}

private final class TerminalDelegate: LocalProcessTerminalViewDelegate {
    let sessionID: Int64
    let onExit: (Int32?) -> Void

    init(sessionID: Int64, onExit: @escaping (Int32?) -> Void) {
        self.sessionID = sessionID
        self.onExit = onExit
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        appLog("[TerminalDelegate] session=\(sessionID) process exited code=\(exitCode ?? -1)")
        onExit(exitCode)
    }
}
