import SwiftUI
import AppKit
import CCHMemory
import CCHSubagents

/// Subagents tab (spec §4): pinned Main row, merge-group sections, category sections, Done.
struct SubagentsTab: View {
    let categoryFilter: Set<SubagentCategory>
    @EnvironmentObject var app: AppState
    @EnvironmentObject var sessions: SessionStore
    @ObservedObject private var client = SubagentsClient.shared
    @State private var doneExpanded = false
    @State private var mainBranch: String?

    static let archivedStates: Set<SubagentState> = [.merged, .stopped, .discarded]

    var body: some View {
        if let session = sessions.activeSession {
            VStack(alignment: .leading, spacing: 0) {
                mainRow(session)
                Divider().background(Theme.border)
                if !client.connected {
                    Text("Connecting to the subagent service…")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textMuted)
                        .padding(12)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        content(session)
                    }
                }
            }
            .onAppear { loadBranch(session) }
            .onChange(of: session.id) { _, _ in loadBranch(session) }
        } else {
            EmptyState(title: "No active session", subtitle: "Select a session to see its subagents.", systemImage: "person.3")
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func content(_ session: Session) -> some View {
        let all = client.snapshots(forSession: session.id)
        let active = all.filter { !Self.archivedStates.contains($0.subagentState) || isInUnfinishedGroup($0, all) }
        let visible = active.filter { categoryFilter.isEmpty || categoryFilter.contains($0.subagentCategory) }
        let groups = Dictionary(grouping: visible.filter { $0.mergeGroupID != nil }, by: { $0.mergeGroupID! })

        if all.isEmpty {
            EmptyState(title: "No subagents yet",
                       subtitle: "Type /task, /bugfix, /feature or /helper in the main terminal.\nEach subagent works in its own git worktree.",
                       systemImage: "person.3")
        }

        ForEach(groups.keys.sorted(), id: \.self) { groupID in
            let members = all.filter { $0.mergeGroupID == groupID && $0.subagentState != .discarded }.sorted { ($0.mergeIndex ?? 0) < ($1.mergeIndex ?? 0) }
            let merged = members.filter { $0.subagentState == .merged }.count
            SectionHeader(title: "Group · \(members.first?.mergeGroupName ?? "?")", trailing: "\(merged)/\(members.count) merged")
            ForEach(members.filter { categoryFilter.isEmpty || categoryFilter.contains($0.subagentCategory) }) { s in
                SubagentRow(snapshot: s, grouped: true, groupMembers: members, session: session)
            }
        }

        ForEach(SubagentCategory.allCases.filter { categoryFilter.isEmpty || categoryFilter.contains($0) }, id: \.self) { category in
            let rows = visible.filter { $0.mergeGroupID == nil && $0.subagentCategory == category }
            SectionHeader(title: category.displayName, trailing: "\(rows.count)")
            if rows.isEmpty {
                Text(Self.placeholder(for: category))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
            ForEach(rows) { s in
                SubagentRow(snapshot: s, grouped: false, groupMembers: [], session: session)
            }
        }

        let done = all.filter { !$0.hidden && ($0.subagentState == .merged || $0.subagentState == .stopped) && !isInUnfinishedGroup($0, all) }
        if !done.isEmpty {
            HStack {
                Button {
                    doneExpanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: doneExpanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
                        Text("DONE").font(.system(size: 9, weight: .bold)).tracking(1)
                        Text("\(done.count)").font(Theme.monoXSmall)
                    }
                    .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
                Spacer()
                Button("Clear") { client.perform("app.clearDone", ["sessionID": Int(session.id)], label: "clear done") }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 4)
            if doneExpanded {
                ForEach(done) { s in SubagentRow(snapshot: s, grouped: false, groupMembers: [], session: session) }
            }
        }
    }

    static func placeholder(for category: SubagentCategory) -> String {
        switch category {
        case .task: return "No tasks. Type /task <what to do> for a scoped change."
        case .bug: return "No bugs. Type /bugfix <the bug> to reproduce, root-cause and fix it."
        case .feature: return "No features. Type /feature <what to build> to implement it with tests."
        case .helper: return "No helpers. Type /helper <what to look into> for research or analysis."
        }
    }

    private func isInUnfinishedGroup(_ s: SubagentSnapshot, _ all: [SubagentSnapshot]) -> Bool {
        guard let groupID = s.mergeGroupID, s.subagentState != .discarded else { return false }
        return all.contains { $0.mergeGroupID == groupID && ![.merged, .discarded].contains($0.subagentState) }
    }

    private func mainRow(_ session: Session) -> some View {
        let selected = app.selectedSubagent[session.id] == nil
        return Button {
            app.selectedSubagent[session.id] = nil
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.inset.filled").font(.system(size: 10)).foregroundStyle(Theme.text2)
                Text("MAIN").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(Theme.text2)
                Text(session.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text1).lineLimit(1)
                if let mainBranch {
                    Text(mainBranch).font(Theme.monoXSmall).foregroundStyle(Theme.textMuted).lineLimit(1)
                }
                Spacer()
                Circle().fill(session.status == .running ? Theme.green : Theme.borderActive).frame(width: 6, height: 6)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(selected ? Theme.bgSh : Theme.bg2)
        }
        .buttonStyle(.plain)
    }

    private func loadBranch(_ session: Session) {
        let dir = session.workingDir
        DispatchQueue.global().async {
            let branch = GitRunner().output(["symbolic-ref", "--short", "-q", "HEAD"], in: dir)
            DispatchQueue.main.async { mainBranch = branch }
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let trailing: String

    var body: some View {
        HStack {
            Text(title.uppercased()).font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(Theme.textMuted)
            Spacer()
            Text(trailing).font(Theme.monoXSmall).foregroundStyle(Theme.textMuted)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

struct SubagentRow: View {
    let snapshot: SubagentSnapshot
    let grouped: Bool
    let groupMembers: [SubagentSnapshot]
    let session: Session
    @EnvironmentObject var app: AppState
    @ObservedObject private var client = SubagentsClient.shared
    @State private var hovering = false

    private var selected: Bool { app.selectedSubagent[session.id] == snapshot.id }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            stateIcon.frame(width: 12, height: 14)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if grouped, let index = snapshot.mergeIndex {
                        Text("\(index)").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.bg1)
                            .frame(width: 14, height: 14).background(Circle().fill(Theme.text2))
                    }
                    if grouped {
                        Text(snapshot.subagentCategory.displayName.uppercased()).font(.system(size: 8, weight: .bold)).tracking(0.5)
                            .foregroundStyle(Theme.text2).padding(.horizontal, 4).padding(.vertical, 1).background(Theme.accentGlow).clipShape(Capsule())
                    }
                    Text(snapshot.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text1).lineLimit(1)
                    if let model = snapshot.model, model != client.defaultModels[snapshot.category] ?? "" {
                        Text(model).font(Theme.monoXSmall).foregroundStyle(Theme.textMuted)
                    }
                }
                if let status = snapshot.lastStatus {
                    Text("\(status)\(snapshot.lastStatusAt.map { " · \(age($0))" } ?? "")")
                        .font(.system(size: 10)).foregroundStyle(Theme.textMuted).lineLimit(2)
                }
                if let note = snapshot.note {
                    Text(note).font(.system(size: 10)).foregroundStyle(snapshot.subagentState == .needsInput ? Theme.red : Theme.text2).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            actionButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(selected ? Theme.bgSh : (hovering ? Theme.bgS : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { app.selectedSubagent[session.id] = snapshot.id }
        .contextMenu { contextMenu }
    }

    // MARK: Pieces

    @ViewBuilder
    private var stateIcon: some View {
        switch snapshot.subagentState {
        case .needsInput: Circle().fill(Theme.red).frame(width: 7, height: 7).padding(.top, 3)
        case .starting, .running, .merging: Circle().fill(Theme.green).frame(width: 7, height: 7).padding(.top, 3)
        case .idle: Circle().fill(Theme.yellow).frame(width: 7, height: 7).padding(.top, 3)
        case .complete: Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.accent)
        case .merged: Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textMuted)
        case .interrupted: Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textMuted)
        case .failed: Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.red)
        case .stopped, .discarded: Circle().fill(Theme.borderActive).frame(width: 7, height: 7).padding(.top, 3)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        let s = snapshot
        switch (s.subagentState, s.subagentMergeSubstate) {
        case (.merging, .awaitingCommit?):
            Text("MERGING…").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textMuted)
        case (.merging, _):
            RowButton(title: "Re-send Merge") { client.perform("app.merge", ["id": Int(s.id)], label: "re-send merge") }
        case (.interrupted, _) where !s.hostAlive:
            RowButton(title: "Resume") { client.perform("app.resume", ["id": Int(s.id)], label: "resume") }
        case (.merged, _):
            Text("MERGED").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textMuted)
        default:
            switch MergeGate.evaluate(s.gateSubagent, groupMembers: groupMembers.map(\.gateSubagent), hasCommits: s.hasCommits, isDirty: s.isDirty) {
            case .success(.merge), .success(.resend):
                RowButton(title: "Merge") { merge() }
            case .success(.archiveNothingToMerge):
                RowButton(title: "Done") { merge() }
            case .failure(.waitsOn(let index)):
                Text("waits #\(index)").font(.system(size: 9)).foregroundStyle(Theme.textMuted)
            case .failure(.busy):
                Text("busy").font(.system(size: 9)).foregroundStyle(Theme.textMuted)
            case .failure(.notMergeable):
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        let s = snapshot
        let id = Int(s.id)
        if [.starting, .running, .idle, .needsInput, .complete, .interrupted].contains(s.subagentState) {
            Button("Stop") { client.perform("app.stop", ["id": id], label: "stop") }
        }
        if !s.hostAlive, [.complete, .stopped, .idle].contains(s.subagentState) {
            Button("Reopen") { client.perform("app.reopen", ["id": id], label: "reopen") }
        }
        Button("Reveal Worktree in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: s.worktreePath) }
        Button("Copy Branch Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s.branch, forType: .string)
        }
        if s.mergeGroupID != nil {
            Button("Remove from Group") { client.perform("app.removeFromGroup", ["id": id], label: "remove from group") }
        }
        if s.subagentState != .merged {
            Divider()
            Button("Discard…", role: .destructive) { confirmDiscard() }
        }
    }

    private func merge() {
        app.selectedSubagent[session.id] = nil
        client.perform("app.merge", ["id": Int(snapshot.id)], label: "merge")
    }

    private func confirmDiscard() {
        let alert = NSAlert()
        alert.messageText = "Discard “\(snapshot.title)”?"
        alert.informativeText = "Stops the subagent and deletes its worktree and branch \(snapshot.branch). Uncommitted and unmerged work is lost."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if app.selectedSubagent[session.id] == snapshot.id { app.selectedSubagent[session.id] = nil }
        client.perform("app.discard", ["id": Int(snapshot.id)], label: "discard")
    }

    private func age(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}

private struct RowButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.bg1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: Theme.rs, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
