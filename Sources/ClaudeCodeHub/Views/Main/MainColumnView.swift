import SwiftUI

struct MainColumnView: View {
    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var app: AppState

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

    private var topbar: some View {
        HStack(spacing: 10) {
            if let session = sessions.activeSession {
                Text(session.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Text(short(session.workingDir))
                    .font(Theme.monoXSmall)
                    .foregroundStyle(Theme.textMuted)
                ForEach(session.tags, id: \.self) { tag in
                    TagChip(text: tag)
                }
            } else {
                Text("No session")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: Theme.topbarHeight)
        .background(Theme.bg2)
    }

    @ViewBuilder
    private var terminalArea: some View {
        if let session = sessions.activeSession {
            TerminalHost(session: session)
                .id(session.id) // force rebuild on session swap; registry caches the actual NSView
                .background(Color.black)
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
