import SwiftUI
import CCHSubagents

/// Right panel: filter chips on top (All · Agents · Task · Bug · Feature · Helper), then the tab strip
/// Subagents | Plans | Scripts, plus MCPs | Agents | Skills while the Agents chip is on.
struct RightPanelView: View {
    @EnvironmentObject var sessions: SessionStore
    @ObservedObject private var subagents = SubagentsClient.shared
    @State private var activeTab: Tab = .subagents
    @State private var agentsMode = false
    @State private var categoryFilter: Set<SubagentCategory> = []
    @StateObject private var scripts = ScriptsModel()

    enum Tab: String, CaseIterable, Hashable {
        case subagents = "Subagents"
        case plans = "Plans"
        case scripts = "Scripts"
        case mcps = "MCPs"
        case agents = "Agents"
        case skills = "Skills"
    }

    private var visibleTabs: [Tab] {
        [.subagents, .plans, .scripts] + (agentsMode ? [.mcps, .agents, .skills] : [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chips
            Divider().background(Theme.border)
            tabStrip
            Divider().background(Theme.border)
            tabContent
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg2)
    }

    private var chips: some View {
        HStack(spacing: 5) {
            FilterChip(title: "All", isOn: categoryFilter.isEmpty) { categoryFilter = [] }
            FilterChip(title: "Agents", isOn: agentsMode) {
                agentsMode.toggle()
                if !agentsMode, [.mcps, .agents, .skills].contains(activeTab) { activeTab = .subagents }
            }
            ForEach(SubagentCategory.allCases, id: \.self) { category in
                FilterChip(title: category.displayName, isOn: categoryFilter.contains(category)) {
                    if categoryFilter.contains(category) { categoryFilter.remove(category) } else { categoryFilter.insert(category) }
                    activeTab = .subagents
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Theme.bg2)
    }

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ForEach(visibleTabs, id: \.self) { tab in
                Button {
                    activeTab = tab
                } label: {
                    HStack(spacing: 5) {
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(activeTab == tab ? Theme.text1 : Theme.textMuted)
                            .lineLimit(1)
                        if let count = count(for: tab) { CountChip(value: count) }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(activeTab == tab ? Theme.accent : .clear)
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .background(Theme.bg3)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch activeTab {
        case .subagents: SubagentsTab(categoryFilter: categoryFilter)
        case .plans: plansTab
        case .scripts: ScriptsTab(model: scripts)
        case .mcps:
            PlaceholderList(title: "MCPs", subtitle: "Discovered MCP servers will appear here.\nToggle to write `.mcp.json` for the active session.", systemImage: "antenna.radiowaves.left.and.right")
        case .agents:
            PlaceholderList(title: "Agents", subtitle: "Markdown agents from `.claude/agents/` will appear here once discovered.", systemImage: "brain")
        case .skills:
            PlaceholderList(title: "Skills", subtitle: "Slash commands from `.claude/skills/` will appear here, grouped by source.", systemImage: "wand.and.stars")
        }
    }

    private var plansTab: some View {
        Group {
            if sessions.activeSession == nil {
                EmptyState(title: "No active session", subtitle: "Select a session to see its plans.", systemImage: "list.bullet.rectangle")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    GroupHeader(title: "Plans", count: 0)
                    EmptyState(title: "No plans yet",
                               subtitle: "Run `/plan create <name>` in the terminal.\nPlans live as markdown files under `.claude/plans/`.",
                               systemImage: "list.bullet.rectangle")
                }
            }
        }
    }

    private func count(for tab: Tab) -> String? {
        switch tab {
        case .subagents:
            guard let id = sessions.activeSessionID else { return "0" }
            return "\(subagents.snapshots(forSession: id).filter { !$0.hidden && !SubagentsTab.archivedStates.contains($0.subagentState) }.count)"
        case .plans: return "0"
        case .scripts: return "\(scripts.scripts.count)"
        case .mcps, .agents, .skills: return nil
        }
    }
}

private struct PlaceholderList: View {
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
            EmptyState(title: title, subtitle: subtitle, systemImage: systemImage)
        }
    }
}

private struct FilterChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isOn ? Theme.bg1 : Theme.text2)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(isOn ? Theme.accent : Theme.bgS)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.rs)
                        .stroke(isOn ? Theme.accent : Theme.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.rs, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
