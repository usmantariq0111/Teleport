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

/// Hero card that prominently displays the active session's passphrase
/// with quick "copy" affordance. Hosts need to share it; joiners get to
/// double-check what they typed against what the host says.
struct PassphraseCard: View {
    let passphrase: Passphrase
    let mode: DaemonMode?

    @State private var copiedPulse = false

    private var headline: String {
        switch mode {
        case .host: return "Share this passphrase with your peer"
        case .join: return "Connected with this passphrase"
        case .none: return "Session passphrase"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
                Text(headline.uppercased())
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(Theme.Palette.textMuted)
                Spacer()
                if copiedPulse {
                    Text("Copied")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.Palette.success)
                        .transition(.opacity)
                }
            }

            HStack(spacing: 12) {
                Text(passphrase.display)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer()
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(passphrase.display, forType: .string)
                    withAnimation(.easeInOut(duration: 0.2)) { copiedPulse = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        withAnimation(.easeOut(duration: 0.4)) { copiedPulse = false }
                    }
                } label: {
                    Label("Copy", systemImage: "doc.on.doc.fill")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.accent)
            }
        }
        .card(padding: Theme.Spacing.md)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .stroke(Theme.Palette.accent.opacity(0.35), lineWidth: 1)
        )
    }
}

/// Lists every IPv4 address the host can be reached on. Designed to sit
/// beside the passphrase card so the user can copy "IP + passphrase" in
/// two clicks and hand both to the joiner — no Terminal required.
struct HostAddressCard: View {
    @ObservedObject var addressBook: LocalAddressBook
    let port: Int

    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "wifi")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
                Text("YOUR ADDRESS")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(Theme.Palette.textMuted)
                Spacer()
                Button {
                    addressBook.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Refresh interfaces")
            }

            if addressBook.addresses.isEmpty {
                Text("No active network interface — connect to Wi-Fi or Ethernet.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.textMuted)
            } else {
                VStack(spacing: 6) {
                    ForEach(addressBook.addresses) { addr in
                        addressRow(addr)
                    }
                }
            }

            Text("Share **one** of these with the joining peer along with the passphrase.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.textMuted)
                .padding(.top, 2)
        }
        .card(padding: Theme.Spacing.md)
    }

    private func addressRow(_ addr: LocalAddressBook.Address) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName(for: addr.label))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(addr.label)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Text(addr.interface)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.Palette.textMuted)
                }
                Text("\(addr.ip):\(port)")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                copy(addr.ip)
            } label: {
                Image(systemName: copied == addr.ip ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(copied == addr.ip ? Theme.Palette.success : Theme.Palette.accent)
            }
            .buttonStyle(.borderless)
            .help("Copy IP")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.Palette.surfaceAlt.opacity(0.5))
        )
    }

    private func iconName(for label: String) -> String {
        switch label {
        case "Wi-Fi":    return "wifi"
        case "Ethernet": return "cable.connector"
        case "VPN":      return "lock.shield"
        default:         return "network"
        }
    }

    private func copy(_ value: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
        copied = value
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if copied == value { copied = nil }
        }
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
