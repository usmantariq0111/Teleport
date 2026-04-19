import SwiftUI
import AppKit

/// Compact menu rendered when the user clicks the bolt in the menu bar.
struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var daemon: DaemonController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            menuButton(
                title: "Open Dashboard",
                systemImage: "rectangle.grid.2x2.fill"
            ) {
                (NSApp.delegate as? AppDelegate)?.showDashboard(using: openWindow)
            }

            if daemon.isRunning {
                menuButton(
                    title: "Stop Daemon",
                    systemImage: "stop.circle.fill",
                    tint: Theme.Palette.danger
                ) {
                    daemon.stopDaemon()
                }
            } else {
                menuButton(
                    title: "Start as Host",
                    systemImage: "antenna.radiowaves.left.and.right"
                ) {
                    daemon.startDaemon(mode: .host)
                }
                menuButton(
                    title: "Join \(daemon.peerIP)",
                    systemImage: "link"
                ) {
                    daemon.startDaemon(mode: .join)
                }
            }

            Divider()

            menuButton(
                title: "Quit Teleport",
                systemImage: "power",
                tint: Theme.Palette.textMuted
            ) {
                daemon.stopDaemon()
                NSApplication.shared.terminate(nil)
            }
        }
        .frame(width: 240)
        .padding(.vertical, 6)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.brandGradient)
                    .frame(width: 28, height: 28)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Teleport")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Text(daemon.isRunning
                     ? "Running • \(daemon.uptimeString)"
                     : "Idle")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Palette.textMuted)
            }
            Spacer()
            Circle()
                .fill(daemon.isRunning ? Theme.Palette.success : Theme.Palette.danger)
                .frame(width: 8, height: 8)
                .shadow(color: daemon.isRunning ? Theme.Palette.success : .clear, radius: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func menuButton(
        title: String,
        systemImage: String,
        tint: Color = .primary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
