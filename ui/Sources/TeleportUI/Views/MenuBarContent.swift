import SwiftUI
import AppKit

/// Compact menu rendered when the user clicks the bolt in the menu bar.
struct MenuBarContent: View {
    @EnvironmentObject var daemon: DaemonController
    @StateObject private var folder = WatchFolderManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            menuButton(
                title: "Open Dashboard",
                systemImage: "rectangle.grid.2x2.fill"
            ) {
                AppDelegate.shared.showDashboard()
            }

            if let _ = folder.folderURL {
                folderRow
            } else {
                menuButton(
                    title: "Choose Folder…",
                    systemImage: "folder.fill.badge.plus",
                    tint: Theme.Palette.accent
                ) {
                    folder.pickFolder()
                }
            }

            // When hosting, surface the passphrase here too so the user
            // doesn't have to open the dashboard just to copy it.
            if daemon.isRunning,
               daemon.mode == .host,
               let pp = daemon.activePassphrase {
                Divider()
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(pp.display, forType: .string)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.Palette.accent)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Passphrase (click to copy)")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.Palette.textMuted)
                            Text(pp.display)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
                    systemImage: "antenna.radiowaves.left.and.right",
                    disabled: folder.folderURL == nil
                ) {
                    daemon.startDaemon(mode: .host)
                }
                // Joining requires a passphrase — that lives in the
                // dashboard. Open it instead of trying to start blindly.
                menuButton(
                    title: "Join a Peer…",
                    systemImage: "link",
                    disabled: folder.folderURL == nil
                ) {
                    AppDelegate.shared.showDashboard()
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

    /// Inline row showing the active folder, with a quick-change action.
    private var folderRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(folder.folderName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(folder.displayPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                folder.pickFolder()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textMuted)
            }
            .buttonStyle(.plain)
            .disabled(daemon.isRunning)
            .help("Change folder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func menuButton(
        title: String,
        systemImage: String,
        tint: Color = .primary,
        disabled: Bool = false,
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
            .foregroundStyle(disabled ? Theme.Palette.textMuted : tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
