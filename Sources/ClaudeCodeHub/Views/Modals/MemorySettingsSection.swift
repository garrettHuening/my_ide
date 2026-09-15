import SwiftUI
import CCHMemory

/// Settings → Memory: grounding strictness for core memory, stored in memory.db so the
/// retrieval hook (a separate process) reads the same value.
struct MemorySettingsSection: View {
    @State private var strictness: GroundingStrictness = .balanced
    @State private var summary: String = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Core memory")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text2)
            Text("Relevant memories are loaded before every prompt. Strictness controls how firmly Claude must cite them.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textMuted)
            HStack(spacing: 10) {
                Text("Grounding")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text2)
                Picker("", selection: $strictness) {
                    ForEach(GroundingStrictness.allCases, id: \.self) { value in
                        Text(value.displayName).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                Spacer()
            }
            Text(error ?? summary)
                .font(.system(size: 10))
                .foregroundStyle(error == nil ? Theme.textMuted : Theme.red)
        }
        .onAppear(perform: load)
        .onChange(of: strictness) { _, newValue in save(newValue) }
    }

    private func load() {
        do {
            let store = try MemoryStore(embedder: nil)
            strictness = try store.strictness()
            let projects = try store.projects()
            let total = try projects.reduce(0) { $0 + (try store.activeMemoryCount(projectID: $1.id)) }
            summary = "\(total) memories across \(projects.count) project\(projects.count == 1 ? "" : "s"). Strict needs at least \(Grounding.strictMinimumMemories) in a project."
        } catch {
            self.error = "Memory database unavailable: \(error)"
        }
    }

    private func save(_ value: GroundingStrictness) {
        do {
            try MemoryStore(embedder: nil).setStrictness(value)
            error = nil
        } catch {
            self.error = "Could not save: \(error)"
        }
    }
}
