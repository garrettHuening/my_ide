import SwiftUI
import Combine
import CCHMemory

/// Loads the most recent session-continuation memory for a project so the user (and, separately,
/// Claude via the retrieval hook) can see where the last session left off.
final class LastSessionModel: ObservableObject {
    struct Summary: Equatable {
        let id: Int64
        let focus: String       // the title after "Session <date> · <project> · "
        let dateLabel: String
        let sections: [(header: String, lines: [String])]

        static func == (a: Summary, b: Summary) -> Bool { a.id == b.id && a.focus == b.focus }
    }

    @Published private(set) var summary: Summary?
    private var loadedFor: String?

    func load(workingDir: String?) {
        guard let workingDir else { summary = nil; loadedFor = nil; return }
        guard loadedFor != workingDir else { return }
        loadedFor = workingDir
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded: Summary? = try? {
                let store = try MemoryStore(embedder: nil)
                let project = try store.project(for: ProjectKey.resolve(directory: workingDir))
                guard let memory = try store.latestSessionMemory(projectID: project.id) else { return nil }
                return Self.parse(memory.id, title: memory.title, body: memory.body)
            }()
            DispatchQueue.main.async {
                guard self.loadedFor == workingDir else { return }
                self.summary = loaded
            }
        }
    }

    func reload(workingDir: String?) {
        loadedFor = nil
        load(workingDir: workingDir)
    }

    /// Title looks like "Session 2026-09-14 · milegacy · <focus>"; body is markdown with ## headers.
    static func parse(_ id: Int64, title: String, body: String) -> Summary {
        let parts = title.components(separatedBy: " · ")
        let focus = parts.count >= 3 ? parts[2...].joined(separator: " · ") : title
        let dateLabel = parts.count >= 2 ? parts[0].replacingOccurrences(of: "Session ", with: "") : ""

        var sections: [(String, [String])] = []
        var currentHeader = ""
        var currentLines: [String] = []
        func flush() {
            if !currentHeader.isEmpty || !currentLines.isEmpty {
                sections.append((currentHeader, currentLines))
            }
        }
        for raw in body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("##") {
                flush()
                currentHeader = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                currentLines = []
            } else if !line.isEmpty {
                currentLines.append(line.hasPrefix("- ") ? String(line.dropFirst(2)) : line)
            }
        }
        flush()
        return Summary(id: id, focus: focus, dateLabel: dateLabel, sections: sections)
    }
}

/// A compact "Last session" card pinned above the main terminal.
struct LastSessionCard: View {
    let workingDir: String
    @StateObject private var model = LastSessionModel()
    @State private var expanded = true
    @State private var dismissed = false

    var body: some View {
        Group {
            if let summary = model.summary, !dismissed {
                VStack(alignment: .leading, spacing: 0) {
                    header(summary)
                    if expanded {
                        Divider().background(Theme.border)
                        details(summary)
                    }
                }
                .background(Theme.bg2)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            }
        }
        .onAppear { model.load(workingDir: workingDir) }
        .onChange(of: workingDir) { _, dir in
            dismissed = false
            expanded = true
            model.reload(workingDir: dir)
        }
    }

    private func header(_ s: LastSessionModel.Summary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.star)
            Text("PICK UP FROM LAST SESSION")
                .font(.system(size: 8, weight: .heavy))
                .tracking(1)
                .foregroundStyle(Theme.textMuted)
            Text(s.focus)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text1)
                .lineLimit(1)
            if !s.dateLabel.isEmpty {
                Text(s.dateLabel)
                    .font(Theme.monoXSmall)
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 6)
            Button { expanded.toggle() } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
            .help(expanded ? "Collapse" : "Expand")
            Button { dismissed = true } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
            .help("Hide until next session")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
    }

    private func details(_ s: LastSessionModel.Summary) -> some View {
        // Lead with Next steps and Open threads — the actionable parts — then the rest.
        let ordered = s.sections.sorted { rank($0.header) < rank($1.header) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(ordered.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 3) {
                        if !section.header.isEmpty {
                            Text(section.header.uppercased())
                                .font(.system(size: 8, weight: .heavy))
                                .tracking(0.8)
                                .foregroundStyle(accent(section.header))
                        }
                        ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•").font(.system(size: 9)).foregroundStyle(Theme.textMuted)
                                Text(line).font(.system(size: 10)).foregroundStyle(Theme.text2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(maxHeight: 180)
    }

    private func rank(_ header: String) -> Int {
        switch header.lowercased() {
        case let h where h.contains("next"): return 0
        case let h where h.contains("open"): return 1
        case let h where h.contains("goal"): return 2
        case let h where h.contains("done"): return 3
        default: return 4
        }
    }

    private func accent(_ header: String) -> Color {
        let h = header.lowercased()
        if h.contains("next") { return Theme.green }
        if h.contains("open") { return Theme.yellow }
        return Theme.textMuted
    }
}
