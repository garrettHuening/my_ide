import SwiftUI

struct SessionRow: View {
    let session: Session
    let isActive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            statusIndicator
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(session.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                        .lineLimit(1)
                    if session.missing {
                        StatusPill(text: "missing", kind: .attention)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 4) {
                    Text(session.workingDir.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("·")
                    Text(session.ageString)
                }
                .font(.system(size: 9))
                .foregroundStyle(Theme.textMuted)

                if !session.tags.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(session.tags.prefix(4), id: \.self) { tag in
                            Text(tag.uppercased())
                                .font(.system(size: 8, weight: .heavy))
                                .tracking(0.3)
                                .foregroundStyle(Theme.text2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Theme.bgS)
                                .overlay(Capsule().stroke(Theme.border, lineWidth: 0.5))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(rowBackground)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.rs)
                .stroke(isActive ? Theme.borderActive : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if session.hasPendingAction {
            // Attention badge — exclamation in a tinted disk.
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.red)
        } else {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
                .shadow(color: session.status == .running ? Theme.green.opacity(0.8) : .clear, radius: 3)
        }
    }

    private var dotColor: Color {
        switch session.status {
        case .running: return Theme.green
        case .paused: return Theme.yellow
        case .stopped: return Theme.textMuted
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: Theme.rs)
            .fill(isActive ? Theme.accentGlow : Color.clear)
    }
}
