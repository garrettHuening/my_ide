import SwiftUI

struct FolderRow: View {
    let folder: Folder
    let sessionCount: Int
    let onToggle: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: folder.expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 12)
            Image(systemName: folder.expanded ? "folder.fill" : "folder")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text2)
            Text(folder.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text1)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(sessionCount)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Theme.bgS)
                .clipShape(Capsule())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .contextMenu {
            Button("Rename…", action: onRename)
            Button("Move up", action: onMoveUp)
            Button("Move down", action: onMoveDown)
            Divider()
            Button("Delete folder", role: .destructive, action: onDelete)
        }
    }
}
