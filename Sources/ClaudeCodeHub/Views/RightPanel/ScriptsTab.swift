import SwiftUI
import Combine
import CCHMemory

/// Loads the active session's script memories (written by the repo sweep).
final class ScriptsModel: ObservableObject {
    struct Script: Identifiable, Equatable {
        let id: Int64
        let name: String
        let command: String?
        let summary: String
    }

    @Published private(set) var scripts: [Script] = []
    @Published private(set) var projectKey: String?
    private var loadedFor: String?

    func load(workingDir: String?, force: Bool = false) {
        guard let workingDir else {
            scripts = []
            projectKey = nil
            loadedFor = nil
            return
        }
        guard force || loadedFor != workingDir else { return }
        loadedFor = workingDir
        DispatchQueue.global(qos: .userInitiated).async {
            let resolved = ProjectKey.resolve(directory: workingDir)
            let loaded: [Script] = (try? {
                let store = try MemoryStore(embedder: nil)
                let project = try store.project(for: resolved)
                return try store.memories(projectID: project.id, kind: .script).map { memory in
                    Script(id: memory.id, name: memory.title, command: ScriptCommand.command(in: memory.body),
                           summary: Grounding.oneLine(ScriptCommand.description(in: memory.body), max: 160))
                }
            }()) ?? []
            DispatchQueue.main.async {
                guard self.loadedFor == workingDir else { return }
                self.scripts = loaded
                self.projectKey = resolved.key
            }
        }
    }
}

struct ScriptsTab: View {
    @EnvironmentObject var sessions: SessionStore
    @ObservedObject var model: ScriptsModel
    @ObservedObject private var sweeps = SweepRunner.shared

    var body: some View {
        Group {
            if let session = sessions.activeSession {
                VStack(alignment: .leading, spacing: 0) {
                    header(session)
                    if model.scripts.isEmpty {
                        EmptyState(
                            title: isSweeping ? "Indexing this project…" : "No scripts yet",
                            subtitle: isSweeping
                                ? "The repo sweep is reading the code and recording scripts, architecture and features."
                                : "Scripts appear after the repo sweep runs. Right-click the session → Re-sweep Project.",
                            systemImage: "terminal"
                        )
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(model.scripts) { script in
                                    ScriptRow(script: script) { command in
                                        TerminalRegistry.shared.sendInput(command, to: session.id)
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                EmptyState(title: "No active session", subtitle: "Select a session to see its scripts.", systemImage: "terminal")
            }
        }
        .onAppear { model.load(workingDir: sessions.activeSession?.workingDir) }
        .onChange(of: sessions.activeSessionID) { _, _ in model.load(workingDir: sessions.activeSession?.workingDir) }
        .onChange(of: sweeps.completedCount) { _, _ in model.load(workingDir: sessions.activeSession?.workingDir, force: true) }
    }

    private var isSweeping: Bool {
        guard let key = model.projectKey else { return !sweeps.running.isEmpty }
        return sweeps.running[key] != nil
    }

    private func header(_ session: Session) -> some View {
        HStack(spacing: 8) {
            GroupHeader(title: "Scripts", count: model.scripts.count)
            Spacer()
            if isSweeping {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.trailing, 12)
    }
}

private struct ScriptRow: View {
    let script: ScriptsModel.Script
    let run: (String) -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            if let command = script.command { run(command) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(script.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                if let command = script.command {
                    Text(command)
                        .font(Theme.monoXSmall)
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !script.summary.isEmpty {
                    Text(script.summary)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(hovering ? Theme.bgS : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(script.command.map { "Type \"\($0)\" into the terminal" } ?? "No command recorded")
    }
}
