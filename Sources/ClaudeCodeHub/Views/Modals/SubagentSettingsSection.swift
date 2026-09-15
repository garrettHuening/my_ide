import SwiftUI
import CCHSubagents

/// Settings → Subagents (R15): default model per category, custom model names, auto-resume.
struct SubagentSettingsSection: View {
    @ObservedObject private var client = SubagentsClient.shared
    @State private var choices: [String: String] = [:]
    @State private var custom: [String: String] = [:]
    @State private var autoResume = true
    @State private var error: String?
    @State private var loaded = false

    private static let options: [(label: String, value: String)] = [
        ("CLI default", ""), ("Fable", "fable"), ("Opus", "opus"), ("Sonnet", "sonnet"), ("Haiku", "haiku"), ("Custom…", "custom")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Subagents")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text2)
            if !client.connected {
                Text("Subagent service isn't running.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textMuted)
            }
            ForEach(SubagentCategory.allCases, id: \.self) { category in
                HStack(spacing: 8) {
                    Text(category.displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text2)
                        .frame(width: 60, alignment: .leading)
                    Picker("", selection: binding(category)) {
                        ForEach(Self.options, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    if choices[category.rawValue] == "custom" {
                        TextField("claude-…", text: customBinding(category), onCommit: save)
                            .textFieldStyle(.roundedBorder)
                            .font(Theme.monoSmall)
                            .frame(width: 220)
                    }
                    Spacer()
                }
            }
            Text("Applies to new subagents. Running ones keep their model.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textMuted)
            Toggle("Resume interrupted subagents automatically", isOn: $autoResume)
                .font(.system(size: 11))
                .foregroundStyle(Theme.text2)
                .onChange(of: autoResume) { _, _ in save() }
            if let error {
                Text(error).font(.system(size: 10)).foregroundStyle(Theme.red)
            }
        }
        .disabled(!client.connected)
        .onAppear(perform: load)
        .onChange(of: client.defaultModels) { _, _ in if !loaded { load() } }
    }

    private func load() {
        guard !client.defaultModels.isEmpty else {
            client.refreshSettings()
            return
        }
        for category in SubagentCategory.allCases {
            let value = client.defaultModels[category.rawValue] ?? ""
            if Self.options.contains(where: { $0.value == value }) {
                choices[category.rawValue] = value
            } else {
                choices[category.rawValue] = "custom"
                custom[category.rawValue] = value
            }
        }
        autoResume = client.autoResume
        loaded = true
    }

    private func binding(_ category: SubagentCategory) -> Binding<String> {
        Binding(get: { choices[category.rawValue] ?? "" },
                set: { value in
                    choices[category.rawValue] = value
                    if value != "custom" { save() }
                })
    }

    private func customBinding(_ category: SubagentCategory) -> Binding<String> {
        Binding(get: { custom[category.rawValue] ?? "" }, set: { custom[category.rawValue] = $0 })
    }

    private func save() {
        guard loaded else { return }
        var models: [String: String] = [:]
        for category in SubagentCategory.allCases {
            let choice = choices[category.rawValue] ?? ""
            let value = choice == "custom" ? (custom[category.rawValue] ?? "").trimmingCharacters(in: .whitespaces) : choice
            if !value.isEmpty && !SubagentModel.isValid(value) {
                error = "\(category.displayName): unknown model '\(value)'. Use fable, opus, sonnet, haiku, or a full claude-… name."
                return
            }
            models[category.rawValue] = value
        }
        client.saveSettings(models: models, autoResume: autoResume) { message in error = message }
    }
}
