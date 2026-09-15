import SwiftUI

/// Right panel: tabs (Tasks | Plans | Panes) sit at the top of the pane list.
/// Filter chips show only under Panes.
struct RightPanelView: View {
    @EnvironmentObject var sessions: SessionStore
    @State private var activeTab: Tab = .panes
    @State private var activeFilters: Set<PaneFilter> = [.all]
    @StateObject private var scripts = ScriptsModel()

    enum Tab: String, CaseIterable, Hashable {
        case tasks = "Tasks"
        case plans = "Plans"
        case scripts = "Scripts"
        case panes = "Panes"
    }

    enum PaneFilter: String, CaseIterable, Hashable {
        case all = "All"
        case analyze = "Analyze"
        case investigate = "Investigate"
        case bug = "Bug"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneFilters
            Divider().background(Theme.border)
            tabStrip
            Divider().background(Theme.border)
            tabContent
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg2)
    }

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button {
                    activeTab = tab
                } label: {
                    HStack(spacing: 6) {
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(activeTab == tab ? Theme.text1 : Theme.textMuted)
                        CountChip(value: count(for: tab))
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
        case .tasks: tasksTab
        case .plans: plansTab
        case .scripts: ScriptsTab(model: scripts)
        case .panes: panesTab
        }
    }

    private var tasksTab: some View {
        if sessions.activeSession == nil {
            return AnyView(EmptyState(
                title: "No active session",
                subtitle: "Select a session to see its task list.",
                systemImage: "checklist"
            ))
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                GroupHeader(title: "Session Tasks", count: 0)
                EmptyState(
                    title: "No tasks yet",
                    subtitle: "Type `todo <description>` or `bug <description>` in the terminal to add one.\nClaude Code Hub mirrors `_tasks.md` at the session root.",
                    systemImage: "checklist"
                )
            }
        )
    }

    private var plansTab: some View {
        if sessions.activeSession == nil {
            return AnyView(EmptyState(
                title: "No active session",
                subtitle: "Select a session to see its plans.",
                systemImage: "list.bullet.rectangle"
            ))
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                GroupHeader(title: "Plans", count: 0)
                EmptyState(
                    title: "No plans yet",
                    subtitle: "Run `/plan create <name>` in the terminal.\nPlans live as markdown files under `.claude/plans/`.",
                    systemImage: "list.bullet.rectangle"
                )
            }
        )
    }

    private var panesTab: some View {
        Group {
            if sessions.activeSession == nil {
                EmptyState(
                    title: "No active session",
                    subtitle: "Sub-agent, bug, and investigate panes appear here.",
                    systemImage: "rectangle.stack"
                )
            } else {
                EmptyState(
                    title: "No panes yet",
                    subtitle: "Type `bug <description>` or `investigate <topic>` to spawn one.\nClaude's `Task` tool also opens panes here.",
                    systemImage: "rectangle.stack"
                )
            }
        }
    }

    private var paneFilters: some View {
        HStack(spacing: 6) {
            ForEach(PaneFilter.allCases, id: \.self) { filter in
                FilterChip(
                    title: filter.rawValue,
                    isOn: activeFilters.contains(filter),
                    action: { toggle(filter) }
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.bg2)
    }

    private func count(for tab: Tab) -> String {
        switch tab {
        case .tasks: return "0/0"
        case .plans: return "0"
        case .scripts: return "\(scripts.scripts.count)"
        case .panes: return "0"
        }
    }

    private func toggle(_ filter: PaneFilter) {
        if filter == .all {
            activeFilters = [.all]
            return
        }
        var next = activeFilters
        next.remove(.all)
        if next.contains(filter) {
            next.remove(filter)
        } else {
            next.insert(filter)
        }
        if next.isEmpty { next = [.all] }
        activeFilters = next
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
                .padding(.horizontal, 9)
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
