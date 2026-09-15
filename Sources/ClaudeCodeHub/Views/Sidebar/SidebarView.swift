import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var sessions: SessionStore

    var body: some View {
        VStack(spacing: 0) {
            header
            SessionsTab()
            autosaveFooter
        }
        .background(Theme.bg2)
    }

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.rs)
                    .stroke(Theme.borderActive, lineWidth: 1)
                Text("CC")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(Theme.text1)
            }
            .frame(width: 24, height: 24)
            Text("Claude Code Hub")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.text1)
                .tracking(-0.3)
            Spacer()
            Button {
                app.showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    private var autosaveFooter: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.green)
                .frame(width: 5, height: 5)
            Text("autosave")
                .font(Theme.monoXSmall)
                .foregroundStyle(Theme.textMuted)
            ProgressView(value: 0.72)
                .progressViewStyle(.linear)
                .tint(Theme.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }
}
