import SwiftUI

/// Shared chip + pill components used across the sidebar, right panel, and panes.
struct CountChip: View {
    let value: String
    var body: some View {
        Text(value)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Theme.textMuted)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Theme.bgS)
            .clipShape(Capsule())
    }
}

struct GroupHeader: View {
    let title: String
    let count: Int?
    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .heavy))
                .tracking(1)
                .foregroundStyle(Theme.textMuted)
            if let count {
                Text("\(count)")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.borderActive)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

struct StatusPill: View {
    let text: String
    let kind: Kind
    enum Kind { case good, attention, neutral, info }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 7, weight: .heavy))
            .tracking(0.3)
            .foregroundStyle(foreground)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(background)
            .overlay(
                Capsule().stroke(border, lineWidth: 0.5)
            )
            .clipShape(Capsule())
    }

    private var foreground: Color {
        switch kind {
        case .good: return Theme.green
        case .attention: return Theme.red
        case .neutral: return Theme.textMuted
        case .info: return Theme.text2
        }
    }
    private var background: Color {
        switch kind {
        case .good: return Theme.green.opacity(0.10)
        case .attention: return Theme.red.opacity(0.10)
        case .neutral: return Theme.bgS
        case .info: return Theme.bgS
        }
    }
    private var border: Color {
        switch kind {
        case .good: return Theme.green.opacity(0.25)
        case .attention: return Theme.red.opacity(0.25)
        case .neutral: return Theme.border
        case .info: return Theme.border
        }
    }
}

struct SearchField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.text1)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Theme.bgS)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.rs)
                .stroke(Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.rs))
    }
}

struct EmptyState: View {
    let title: String
    let subtitle: String?
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.borderActive)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text2)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }
}
