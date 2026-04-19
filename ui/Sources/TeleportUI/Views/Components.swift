import SwiftUI

/// Glowing status pill (Connected / Disconnected / Hosting / Joined).
struct StatusPill: View {
    let isRunning: Bool
    let mode: DaemonMode?

    private var label: String {
        guard isRunning else { return "Disconnected" }
        switch mode {
        case .host: return "Hosting"
        case .join: return "Joined"
        case .none: return "Connected"
        }
    }

    private var color: Color {
        isRunning ? Theme.Palette.success : Theme.Palette.danger
    }

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .shadow(color: color.opacity(0.85), radius: pulse ? 8 : 2)
                .scaleEffect(pulse ? 1.15 : 1.0)
                .animation(
                    isRunning
                        ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                        : .default,
                    value: pulse
                )
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(color.opacity(0.12))
        )
        .overlay(
            Capsule().stroke(color.opacity(0.35), lineWidth: 1)
        )
        .onAppear { pulse = isRunning }
        .onChange(of: isRunning) { _, newValue in pulse = newValue }
    }
}

/// Compact stat block used in the dashboard.
struct StatTile: View {
    let title: String
    let value: String
    let systemImage: String
    var tint: Color = Theme.Palette.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(Theme.Palette.textMuted)
            }
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// Primary CTA button styled with the brand gradient.
struct PrimaryButton: View {
    let title: String
    let systemImage: String?
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(Theme.brandGradient)
                    .opacity(hovering ? 0.92 : 1.0)
                    .shadow(color: Theme.Palette.accent.opacity(0.35), radius: hovering ? 12 : 6, y: 3)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Subtle secondary button.
struct SecondaryButton: View {
    let title: String
    let systemImage: String?
    let role: ButtonRole?
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.action = action
    }

    @State private var hovering = false

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title).font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(role == .destructive ? Theme.Palette.danger : .primary)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(Theme.Palette.surfaceAlt.opacity(hovering ? 0.95 : 0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .stroke(Theme.Palette.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Small label/value row used in side panels.
struct InfoRow: View {
    let label: String
    let value: String
    var monospaced: Bool = false

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Palette.textMuted)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: monospaced ? .monospaced : .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
