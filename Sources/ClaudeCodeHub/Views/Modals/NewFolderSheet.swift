import SwiftUI

struct NewFolderSheet: View {
    @Binding var name: String
    var onCancel: () -> Void
    var onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New folder")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text1)
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(Theme.bg2)
    }
}
