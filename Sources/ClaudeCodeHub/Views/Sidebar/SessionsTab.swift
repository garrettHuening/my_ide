import SwiftUI

struct SessionsTab: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var importer: SessionImporter
    @EnvironmentObject var folders: FolderStore

    @State private var renameSessionTarget: Session?
    @State private var renameFolderTarget: Folder?
    @State private var renameDraft: String = ""
    @State private var searchText: String = ""

    @State private var showNewFolder: Bool = false
    @State private var newFolderName: String = ""
    @State private var filter: SessionFilter = .all

    enum SessionFilter: String, CaseIterable, Identifiable {
        case favorites = "Favorites"
        case active = "Active"
        case all = "All"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .favorites: return "star.fill"
            case .active: return "bolt.fill"
            case .all: return "square.stack.3d.up.fill"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            actionRow
            filterBar
            listSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $renameSessionTarget) { target in
            RenameSheet(
                title: "Rename session",
                draft: $renameDraft,
                onCancel: { renameSessionTarget = nil },
                onConfirm: {
                    sessions.rename(target.id, to: renameDraft)
                    renameSessionTarget = nil
                }
            )
        }
        .sheet(item: $renameFolderTarget) { target in
            RenameSheet(
                title: "Rename folder",
                draft: $renameDraft,
                onCancel: { renameFolderTarget = nil },
                onConfirm: {
                    folders.rename(target.id, to: renameDraft)
                    renameFolderTarget = nil
                }
            )
        }
        .sheet(isPresented: $showNewFolder) {
            NewFolderSheet(
                name: $newFolderName,
                onCancel: { showNewFolder = false },
                onConfirm: {
                    _ = folders.create(name: newFolderName)
                    newFolderName = ""
                    showNewFolder = false
                }
            )
        }
    }

    private var actionRow: some View {
        HStack(spacing: 5) {
            SearchField(text: $searchText, placeholder: "Search sessions…")

            Button {
                _ = importer.scan()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: Theme.rs).stroke(Theme.border))
            }
            .buttonStyle(.plain)
            .help("Import sessions from \(shortPath(app.prefs.claudeStateDir))")

            Menu {
                Button("New Session…") { app.showNewSessionModal = true }
                Button("New Folder…") {
                    newFolderName = ""
                    showNewFolder = true
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: Theme.rs).stroke(Theme.border))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28, height: 28)
            .help("Create…")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var filterBar: some View {
        HStack(spacing: 4) {
            ForEach(SessionFilter.allCases) { f in
                FilterPill(
                    title: f.rawValue,
                    icon: f.icon,
                    count: count(for: f),
                    isOn: filter == f,
                    action: { filter = f }
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func count(for f: SessionFilter) -> Int {
        sessions.displayedSessions.filter { matches($0, filter: f) }.count
    }

    private func matches(_ s: Session, filter f: SessionFilter) -> Bool {
        switch f {
        case .favorites: return s.isFavorite
        case .active: return s.status == .running || s.hasPendingAction
        case .all: return true
        }
    }

    private var filtered: [Session] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return sessions.displayedSessions.filter { s in
            guard matches(s, filter: filter) else { return false }
            guard !q.isEmpty else { return true }
            return s.name.lowercased().contains(q)
                || s.workingDir.lowercased().contains(q)
                || s.tagsRaw.lowercased().contains(q)
        }
    }

    private func sessions(in folder: Folder?) -> [Session] {
        let folderID = folder?.id
        return filtered.filter { $0.folderID == folderID }
            .sorted { ($0.sortOrder, $0.updatedAt) < ($1.sortOrder, $1.updatedAt) }
    }

    private var listSection: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                let rows = filtered
                if rows.isEmpty {
                    emptyState
                } else {
                    folderSections
                    ungroupedSection
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.isEmpty {
            EmptyState(
                title: "No matches",
                subtitle: "Nothing in this list matches \"\(searchText)\".",
                systemImage: "magnifyingglass"
            )
            .frame(minHeight: 180)
        } else if filter == .favorites {
            EmptyState(
                title: "No favorites yet",
                subtitle: "Tap the star on a session to pin it here.",
                systemImage: "star"
            )
            .frame(minHeight: 180)
        } else if filter == .active {
            EmptyState(
                title: "Nothing running",
                subtitle: "Sessions that are running or waiting on you show up here.",
                systemImage: "bolt"
            )
            .frame(minHeight: 180)
        } else {
            EmptyState(
                title: "No sessions",
                subtitle: "Press + to create one, or refresh to import from\n\(shortPath(app.prefs.claudeStateDir)).",
                systemImage: "tray"
            )
            .frame(minHeight: 220)
        }
    }

    @ViewBuilder
    private var folderSections: some View {
        let folderList = folders.folders
        if !folderList.isEmpty {
            ForEach(folderList) { folder in
                let inFolder = sessions(in: folder)
                FolderRow(
                    folder: folder,
                    sessionCount: inFolder.count,
                    onToggle: { folders.toggleExpanded(folder.id) },
                    onRename: {
                        renameDraft = folder.name
                        renameFolderTarget = folder
                    },
                    onDelete: { folders.delete(folder.id) },
                    onMoveUp: { moveFolder(folder, by: -1) },
                    onMoveDown: { moveFolder(folder, by: 1) }
                )
                .onDrop(of: ["public.text"], delegate: FolderDropDelegate(
                    folder: folder,
                    sessions: sessions,
                    onAccept: { id in sessions.moveToFolder(id, folderID: folder.id) }
                ))
                if folder.expanded {
                    if inFolder.isEmpty {
                        Text("Empty — drag a session here.")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textMuted)
                            .padding(.leading, 30)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(inFolder) { session in
                            sessionRowView(session, indent: true)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var ungroupedSection: some View {
        let rows = sessions(in: nil)
        if !rows.isEmpty {
            if !folders.folders.isEmpty {
                GroupHeader(title: "Ungrouped", count: rows.count)
            } else {
                GroupHeader(title: "Imported", count: rows.filter { $0.source == .imported }.count)
            }
            ForEach(rows) { session in
                sessionRowView(session, indent: false)
                    .onDrop(of: ["public.text"], delegate: SessionMoveDelegate(
                        target: nil,
                        sessions: sessions
                    ))
            }
        }
    }

    @ViewBuilder
    private func sessionRowView(_ session: Session, indent: Bool) -> some View {
        SessionRow(
            session: session,
            isActive: session.id == sessions.activeSessionID,
            onToggleFavorite: { sessions.toggleFavorite(session.id) }
        )
        .padding(.leading, indent ? 18 : 0)
        .onTapGesture { sessions.switchTo(session.id) }
        .onDrag {
            NSItemProvider(object: "\(session.id)" as NSString)
        }
        .contextMenu {
            Button(session.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                sessions.toggleFavorite(session.id)
            }
            Button("Rename…") {
                renameDraft = session.name
                renameSessionTarget = session
            }
            if !folders.folders.isEmpty {
                Menu("Move to") {
                    Button("Ungrouped") { sessions.moveToFolder(session.id, folderID: nil) }
                    ForEach(folders.folders) { folder in
                        Button(folder.name) { sessions.moveToFolder(session.id, folderID: folder.id) }
                    }
                }
            }
            Menu("Core Memory") {
                Button("Re-sweep Project") { MemoryJobs.shared.sweepNow(workingDir: session.workingDir) }
                Button("Add Documentation URL…") { DocumentationPicker.askForURL(workingDir: session.workingDir) }
                Button("Add Documentation Files…") { DocumentationPicker.askForFiles(workingDir: session.workingDir) }
                Button("Dream Now") { MemoryJobs.shared.dreamNow(workingDir: session.workingDir) }
            }
            Divider()
            Button("Delete", role: .destructive) { sessions.delete(session.id) }
        }
    }

    private func moveFolder(_ folder: Folder, by delta: Int) {
        let list = folders.folders
        guard let idx = list.firstIndex(where: { $0.id == folder.id }) else { return }
        let newIdx = idx + delta
        guard newIdx >= 0 && newIdx < list.count else { return }
        // Place the target between its new neighbors (fractional sort_order).
        let prev = newIdx == 0 ? 0 : list[newIdx - (delta > 0 ? 0 : 1)].sortOrder
        let next: Double = {
            if delta > 0 {
                return newIdx + 1 < list.count ? list[newIdx + 1].sortOrder : list[newIdx].sortOrder + 2
            } else {
                return list[newIdx].sortOrder
            }
        }()
        let target = (prev + next) / 2
        folders.setSortOrder(folder.id, target)
    }

    private func shortPath(_ p: String) -> String {
        p.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

/// A compact segmented filter pill (Favorites · Active · All) with an icon and count.
private struct FilterPill: View {
    let title: String
    let icon: String
    let count: Int
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .bold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isOn ? Theme.selectionText.opacity(0.7) : Theme.textMuted)
            }
            .foregroundStyle(isOn ? Theme.selectionText : Theme.text2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isOn ? Theme.selection : Theme.bgS)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.rs)
                    .stroke(isOn ? Theme.selection.opacity(0.9) : Theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.rs, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct RenameSheet: View {
    let title: String
    @Binding var draft: String
    var onCancel: () -> Void
    var onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text1)
            TextField("Name", text: $draft)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(Theme.bg2)
    }
}

// MARK: - Drag-and-drop

private struct FolderDropDelegate: DropDelegate {
    let folder: Folder
    let sessions: SessionStore
    let onAccept: (Int64) -> Void

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: ["public.text"]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { (obj, _) in
            guard let str = obj as? String, let id = Int64(str) else { return }
            DispatchQueue.main.async { onAccept(id) }
        }
        return true
    }
}

private struct SessionMoveDelegate: DropDelegate {
    let target: Int64?  // session id to insert before, or nil = end of ungrouped
    let sessions: SessionStore

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: ["public.text"]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { (obj, _) in
            guard let str = obj as? String, let id = Int64(str) else { return }
            DispatchQueue.main.async {
                sessions.moveToFolder(id, folderID: nil)
            }
        }
        return true
    }
}
