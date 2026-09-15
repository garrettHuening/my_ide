import SwiftUI
import AppKit

struct SettingsSheet: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var prefs: PrefsStore
    @EnvironmentObject var importer: SessionImporter
    @EnvironmentObject var sessions: SessionStore

    @State private var dirField: String = ""
    @State private var scanResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Settings")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Claude state directory")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                Text("The Hub imports a session for each subfolder. Default: ~/.claude/projects")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textMuted)
                HStack(spacing: 6) {
                    TextField("~/.claude/projects", text: $dirField)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.monoSmall)
                    Button("Choose…") { pickDirectory() }
                    Button("Default") {
                        dirField = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
                    }
                    .help("Reset to ~/.claude/projects")
                }
            }

            Divider().background(Theme.border)

            MemorySettingsSection()

            Divider().background(Theme.border)

            HStack(spacing: 10) {
                Button {
                    apply()
                    let added = importer.scan()
                    scanResult = added == 0
                        ? "No new sessions (already imported)."
                        : "Imported \(added) new session\(added == 1 ? "" : "s")."
                } label: {
                    Label("Scan now", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .foregroundStyle(Theme.bg1)

                if let scanResult {
                    Text(scanResult)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text2)
                }
                if let err = importer.lastError {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.red)
                }
                Spacer()
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done") {
                    apply()
                    app.showSettings = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 540, height: 540)
        .background(Theme.bg2)
        .onAppear { dirField = prefs.claudeStateDir }
    }

    private func apply() {
        prefs.setClaudeStateDir(expandTilde(dirField))
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        let start = expandTilde(dirField)
        if FileManager.default.fileExists(atPath: start) {
            panel.directoryURL = URL(fileURLWithPath: start)
        }
        if panel.runModal() == .OK, let url = panel.url {
            dirField = url.path
        }
    }

    private func expandTilde(_ s: String) -> String {
        (s as NSString).expandingTildeInPath
    }
}
