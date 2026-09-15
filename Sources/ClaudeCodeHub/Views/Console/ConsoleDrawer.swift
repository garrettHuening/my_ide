import SwiftUI
import AppKit
import Combine
import CCHMemory

/// Reads the shared console log while the drawer is open.
final class ConsoleModel: ObservableObject {
    @Published private(set) var entries: [LogEntry] = []
    @Published private(set) var domains: [String] = []
    @Published var selectedDomains: Set<String> = [] { didSet { refresh() } }
    @Published var minimumSeverity: LogSeverity = .debug { didSet { refresh() } }
    @Published var searchText: String = "" { didSet { refresh() } }
    @Published var currentProjectOnly = false { didSet { refresh() } }
    @Published private(set) var unavailable: String?

    private var timer: Timer?
    private var currentProjectID: Int64?
    private let queue = DispatchQueue(label: "cch.console.read")

    func start(workingDir: String?) {
        setWorkingDir(workingDir)
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func setWorkingDir(_ workingDir: String?) {
        guard let workingDir else {
            currentProjectID = nil
            return
        }
        queue.async {
            let id = try? MemoryStore(embedder: nil).project(for: ProjectKey.resolve(directory: workingDir)).id
            DispatchQueue.main.async {
                self.currentProjectID = id
                self.refresh()
            }
        }
    }

    func refresh() {
        let domains = selectedDomains
        let severity = minimumSeverity
        let text = searchText
        let projectID = currentProjectOnly ? currentProjectID : nil
        let projectOnly = currentProjectOnly
        queue.async {
            do {
                let log = try ConsoleLog()
                var entries = try log.recent(limit: 1000, domains: domains, minimumSeverity: severity, text: text)
                if projectOnly { entries = entries.filter { $0.projectID == projectID } }
                let all = try log.domains()
                DispatchQueue.main.async {
                    self.entries = entries
                    self.domains = all
                    self.unavailable = nil
                }
            } catch {
                DispatchQueue.main.async { self.unavailable = "Console unavailable: \(error)" }
            }
        }
    }

    func copyFiltered() {
        let formatter = ISO8601DateFormatter()
        let text = entries.reversed().map { entry in
            var line = "\(formatter.string(from: entry.at)) [\(entry.severity.rawValue)] \(entry.domain) (\(entry.source)) \(entry.message)"
            if let data = entry.dataJSON { line += " \(data)" }
            return line
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// One debug console for everything (spec section 4): Hub, memory, sweeps, sessions, Claude and
/// any external process writing through `cch-mcp log`.
struct ConsoleDrawer: View {
    @EnvironmentObject var sessions: SessionStore
    @StateObject private var model = ConsoleModel()
    @State private var expanded: Set<Int64> = []

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().background(Theme.border)
            if let message = model.unavailable {
                Text(message).font(Theme.monoXSmall).foregroundStyle(Theme.red).padding(8)
                Spacer(minLength: 0)
            } else if model.entries.isEmpty {
                Text("No log entries match.")
                    .font(Theme.monoXSmall)
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.entries, id: \.id) { entry in
                            row(entry)
                        }
                    }
                }
            }
        }
        .frame(height: 230)
        .background(Theme.bgT)
        .onAppear { model.start(workingDir: sessions.activeSession?.workingDir) }
        .onDisappear { model.stop() }
        .onChange(of: sessions.activeSessionID) { _, _ in model.setWorkingDir(sessions.activeSession?.workingDir) }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("CONSOLE")
                .font(.system(size: 9, weight: .bold))
                .tracking(1)
                .foregroundStyle(Theme.text2)
            Menu {
                Button("All domains") { model.selectedDomains = [] }
                Divider()
                ForEach(model.domains, id: \.self) { domain in
                    Button {
                        if model.selectedDomains.contains(domain) { model.selectedDomains.remove(domain) } else { model.selectedDomains.insert(domain) }
                    } label: {
                        if model.selectedDomains.contains(domain) { Label(domain, systemImage: "checkmark") } else { Text(domain) }
                    }
                }
            } label: {
                Text(model.selectedDomains.isEmpty ? "All domains" : model.selectedDomains.sorted().joined(separator: ", "))
                    .font(.system(size: 10))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Picker("", selection: $model.minimumSeverity) {
                ForEach(LogSeverity.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 90)
            Toggle("This project", isOn: $model.currentProjectOnly)
                .toggleStyle(.checkbox)
                .font(.system(size: 10))
            TextField("Filter", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10))
                .frame(maxWidth: 200)
            Spacer()
            Text("\(model.entries.count)")
                .font(Theme.monoXSmall)
                .foregroundStyle(Theme.textMuted)
            Button("Copy Filtered") { model.copyFiltered() }
                .font(.system(size: 10))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.bg3)
    }

    private func row(_ entry: LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(color(entry.severity)).frame(width: 6, height: 6)
                Text(Self.time.string(from: entry.at))
                    .foregroundStyle(Theme.textMuted)
                Text(entry.domain)
                    .foregroundStyle(Theme.text2)
                    .frame(width: 110, alignment: .leading)
                    .lineLimit(1)
                Text(entry.message)
                    .foregroundStyle(entry.severity == .error ? Theme.red : Theme.text1)
                    .lineLimit(expanded.contains(entry.id) ? nil : 1)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Text(entry.source)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
            if expanded.contains(entry.id), let data = entry.dataJSON {
                Text(data)
                    .foregroundStyle(Theme.text2)
                    .textSelection(.enabled)
                    .padding(.leading, 14)
            }
        }
        .font(Theme.monoXSmall)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            if expanded.contains(entry.id) { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
        }
    }

    private func color(_ severity: LogSeverity) -> Color {
        switch severity {
        case .debug: return Theme.borderActive
        case .info: return Theme.green
        case .warning: return Theme.yellow
        case .error: return Theme.red
        }
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
