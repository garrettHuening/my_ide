import SwiftUI
import CCHSubagents

/// Thin status bar pinned to the bottom of the window — mirrors the wireframe's
/// .sbar pattern. Shows context, session state, and a few quick indicators.
struct StatusBar: View {
    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var app: AppState
    @ObservedObject private var jobs = MemoryJobs.shared
    @ObservedObject private var subagents = SubagentsClient.shared

    var body: some View {
        HStack(spacing: 14) {
            indicator(color: Theme.green, label: stateLabel)
            indicator(color: Theme.borderActive, label: "ctx 0%")
            indicator(color: subagents.connected ? Theme.borderActive : Theme.red, label: subagentLabel)
            if needYou > 0 {
                indicator(color: Theme.red, label: "\(needYou) need you")
            }
            if !jobs.running.isEmpty {
                indicator(color: Theme.yellow, label: "\(jobs.running.values.sorted().joined(separator: ", "))…")
            }
            Spacer()
            Button {
                app.consoleVisible.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.bottomthird.inset.filled")
                        .font(.system(size: 9))
                    Text("console")
                        .font(.system(size: 9))
                }
                .foregroundStyle(app.consoleVisible ? Theme.text1 : Theme.textMuted)
            }
            .buttonStyle(.plain)
            .help("Show or hide the debug console (⇧⌘Y)")
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

    private var activeSubagents: [CCHSubagents.SubagentSnapshot] {
        subagents.snapshots.filter { ![.merged, .stopped, .discarded, .failed].contains($0.subagentState) }
    }

    private var subagentLabel: String {
        guard subagents.connected else { return "helper offline" }
        return "\(activeSubagents.count) subagent\(activeSubagents.count == 1 ? "" : "s")"
    }

    private var needYou: Int {
        activeSubagents.filter { $0.subagentState == .needsInput }.count
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
