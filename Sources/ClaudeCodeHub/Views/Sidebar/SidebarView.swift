import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var sessions: SessionStore

    var body: some View {
        VStack(spacing: 0) {
            header
            tabStrip
            tabContent
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

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ForEach(AppState.SidebarTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    private func tabButton(_ tab: AppState.SidebarTab) -> some View {
        Button {
            app.sidebarTab = tab
        } label: {
            Text(tab.rawValue)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(app.sidebarTab == tab ? Theme.text1 : Theme.textMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(app.sidebarTab == tab ? Theme.accent : .clear)
                        .frame(height: 2)
                }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch app.sidebarTab {
        case .sessions: SessionsTab()
        case .mcps:
            ListEmptyState(
                title: "MCPs",
                subtitle: "Discovered HTTP MCP servers will appear here.\nToggle to write `.mcp.json` for the active session.",
                systemImage: "antenna.radiowaves.left.and.right"
            )
        case .agents:
            ListEmptyState(
                title: "Agents",
                subtitle: "Markdown agents from `.claude/agents/` will appear here once discovered.",
                systemImage: "brain"
            )
        case .skills:
            ListEmptyState(
                title: "Skills",
                subtitle: "Slash commands from `.claude/skills/` will appear here, grouped by source.",
                systemImage: "wand.and.stars"
            )
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

private struct ListEmptyState: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $searchText, placeholder: "Search \(title.lowercased())…")
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)
            EmptyState(
                title: title,
                subtitle: subtitle,
                systemImage: systemImage
            )
        }
    }
}
