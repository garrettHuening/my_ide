import SwiftUI

/// Thin status bar pinned to the bottom of the window — mirrors the wireframe's
/// .sbar pattern. Shows context, session state, and a few quick indicators.
struct StatusBar: View {
    @EnvironmentObject var sessions: SessionStore

    var body: some View {
        HStack(spacing: 14) {
            indicator(color: Theme.green, label: stateLabel)
            indicator(color: Theme.borderActive, label: "ctx 0%")
            indicator(color: Theme.borderActive, label: "0 panes")
            indicator(color: Theme.borderActive, label: "0 tasks")
            Spacer()
            indicator(color: Theme.borderActive, label: workingDirLabel)
            indicator(color: Theme.borderActive, label: "v0.1")
        }
        .padding(.horizontal, 12)
        .frame(height: 22)
        .background(Theme.bg3)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    private var stateLabel: String {
        if let s = sessions.activeSession {
            return "\(s.name) · \(s.status.rawValue)"
        }
        return "no session"
    }

    private var workingDirLabel: String {
        guard let s = sessions.activeSession else { return "—" }
        return s.workingDir.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func indicator(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
        }
    }
}
