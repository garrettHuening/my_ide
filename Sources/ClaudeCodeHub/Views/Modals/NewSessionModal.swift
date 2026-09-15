import SwiftUI
import AppKit

struct NewSessionModal: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var sessions: SessionStore

    @State private var name: String = ""
    @State private var workingDir: String = (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path) ?? NSHomeDirectory()
    @State private var tagsText: String = ""
    @State private var agentFile: String = ""
    @State private var initialPrompt: String = ""
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Session")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text1)

            field("Name", required: true) {
                TextField("e.g. wifi-debug", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            field("Working directory", required: true) {
                HStack(spacing: 6) {
                    TextField("/path/to/project", text: $workingDir)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { pickDirectory() }
                }
            }

            field("Tags") {
                TextField("comma-separated, e.g. wifi,driver", text: $tagsText)
                    .textFieldStyle(.roundedBorder)
            }

            field("Agent file") {
                HStack(spacing: 6) {
                    TextField(".claude/agents/foo.md (optional)", text: $agentFile)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { pickAgentFile() }
                }
            }

            field("Initial prompt") {
                TextEditor(text: $initialPrompt)
                    .font(Theme.monoSmall)
                    .frame(minHeight: 80, maxHeight: 120)
                    .padding(6)
                    .background(Theme.bgS)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.rs))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.rs)
                            .stroke(Theme.border)
                    )
            }

            if let errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { app.showNewSessionModal = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(Theme.bg2)
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, required: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                if required {
                    Text("*")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.red)
                }
            }
            content()
        }
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            workingDir = url.path
        }
    }

    private func pickAgentFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []  // accept anything; agent files are .md but don't restrict
        if panel.runModal() == .OK, let url = panel.url {
            agentFile = url.path
        }
    }

    private func submit() {
        errorText = nil
        let tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let input = SessionStore.NewSession(
            name: name,
            workingDir: workingDir,
            tags: tags,
            agentFile: agentFile.isEmpty ? nil : agentFile,
            initialPrompt: initialPrompt.isEmpty ? nil : initialPrompt
        )
        do {
            _ = try sessions.createOrSwitch(input)
            app.showNewSessionModal = false
        } catch {
            errorText = "\(error)"
        }
    }
}
