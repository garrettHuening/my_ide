import SwiftUI
import CCHMemory

/// Settings → Memory. Values live in memory.db so the hook and sweep processes read the same ones.
struct MemorySettingsSection: View {
    @State private var strictness: GroundingStrictness = .balanced
    @State private var backgroundModel: String = MemoryStore.defaultBackgroundModel
    @State private var autoSweep = true
    @State private var summary: String = ""
    @State private var error: String?
    @State private var loaded = false

    private static let models: [(label: String, value: String)] = [
        ("Sonnet", "sonnet"), ("Opus", "opus"), ("Haiku", "haiku"), ("Fable", "fable")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Core memory")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text2)
            Text("Relevant memories are loaded before every prompt. Strictness controls how firmly Claude must cite them.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textMuted)

            row("Grounding") {
                Picker("", selection: $strictness) {
                    ForEach(GroundingStrictness.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }
            row("Background model") {
                Picker("", selection: $backgroundModel) {
                    ForEach(Self.models, id: \.value) { Text($0.label).tag($0.value) }
                }
                .labelsHidden()
                .frame(width: 140)
                Text("repo sweeps")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textMuted)
            }
            Toggle("Sweep new projects automatically when a session opens", isOn: $autoSweep)
                .font(.system(size: 11))
                .foregroundStyle(Theme.text2)

            Text(error ?? summary)
                .font(.system(size: 10))
                .foregroundStyle(error == nil ? Theme.textMuted : Theme.red)
        }
        .onAppear(perform: load)
        .onChange(of: strictness) { _, value in save { try $0.setStrictness(value) } }
        .onChange(of: backgroundModel) { _, value in save { try $0.setPref(MemoryStore.backgroundModelKey, value) } }
        .onChange(of: autoSweep) { _, value in save { try $0.setPref(MemoryStore.autoSweepKey, value ? "1" : "0") } }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.text2)
                .frame(width: 110, alignment: .leading)
            content()
            Spacer()
        }
    }

    private func load() {
        do {
            let store = try MemoryStore(embedder: nil)
            strictness = try store.strictness()
            backgroundModel = try store.backgroundModel()
            autoSweep = try store.autoSweep()
            let projects = try store.projects()
            let total = try projects.reduce(0) { $0 + (try store.activeMemoryCount(projectID: $1.id)) }
            summary = "\(total) memories across \(projects.count) project\(projects.count == 1 ? "" : "s"). Strict needs at least \(Grounding.strictMinimumMemories) in a project."
            loaded = true
        } catch {
            self.error = "Memory database unavailable: \(error)"
        }
    }

    private func save(_ change: (MemoryStore) throws -> Void) {
        guard loaded else { return }
        do {
            try change(try MemoryStore(embedder: nil))
            error = nil
        } catch {
            self.error = "Could not save: \(error)"
        }
    }
}
