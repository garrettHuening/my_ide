import SwiftUI
import CCHSubagents

struct MainColumnView: View {
    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var app: AppState
    @ObservedObject private var subagents = SubagentsClient.shared

    var body: some View {
        VStack(spacing: 0) {
            topbar
            Divider().background(Theme.border)
            terminalArea
            if app.consoleVisible {
                Divider().background(Theme.border)
                ConsoleDrawer()
            }
        }
        .background(Theme.bg1)
    }

    private var selectedSubagent: SubagentSnapshot? {
        guard let session = sessions.activeSession, let id = app.selectedSubagent[session.id] else { return nil }
        return subagents.snapshot(id)
    }

    private var topbar: some View {
        HStack(spacing: 10) {
            if let session = sessions.activeSession {
                if let s = selectedSubagent {
                    Text(s.subagentCategory.displayName.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(Theme.bg1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accent)
                        .clipShape(Capsule())
                    Text(s.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                        .lineLimit(1)
                    Text(s.branch)
                        .font(Theme.monoXSmall)
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        app.selectedSubagent[session.id] = nil
                    } label: {
                        Label("Back to Main", systemImage: "arrow.uturn.left")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.text2)
                } else {
                    Text("MAIN")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(Theme.text2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accentGlow)
                        .clipShape(Capsule())
                    Text(session.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                    Text(short(session.workingDir))
                        .font(Theme.monoXSmall)
                        .foregroundStyle(Theme.textMuted)
                    ForEach(session.tags, id: \.self) { tag in
                        TagChip(text: tag)
                    }
                    Spacer()
                }
            } else {
                Text("No session")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textMuted)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Theme.topbarHeight)
        .background(Theme.bg2)
    }

    @ViewBuilder
    private var terminalArea: some View {
        if let session = sessions.activeSession {
            if let s = selectedSubagent {
                VStack(spacing: 0) {
                    SubagentTerminalHost(agentID: s.id)
                        .id("subagent-\(s.id)")
                        .background(Color.black)
                    if !s.hostAlive, [.complete, .stopped, .idle, .interrupted].contains(s.subagentState) {
                        reopenBar(s)
                    }
                }
            } else {
                TerminalHost(session: session)
                    .id(session.id) // force rebuild on session swap; registry caches the actual NSView
                    .background(Color.black)
            }
        } else {
            ZStack {
                Theme.bgT
                Text("Create or select a session to start a Claude conversation.")
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textMuted)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func reopenBar(_ s: SubagentSnapshot) -> some View {
        HStack(spacing: 10) {
            Text(s.subagentState == .interrupted ? "This subagent was interrupted." : "Claude isn't running for this subagent (saved output shown).")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text2)
            Spacer()
            Button(s.subagentState == .interrupted ? "Resume" : "Reopen") {
                SubagentsClient.shared.perform(s.subagentState == .interrupted ? "app.resume" : "app.reopen", ["id": Int(s.id)], label: "reopen")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.bg3)
    }

    private func short(_ p: String) -> String {
        p.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

private struct TagChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.accentGlow)
            .clipShape(Capsule())
    }
}
