import SwiftUI

enum DashboardTab: String, CaseIterable, Identifiable {
    case dashboard, logs, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .logs:      return "Live Logs"
        case .settings:  return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "bolt.horizontal.fill"
        case .logs:      return "terminal.fill"
        case .settings:  return "gearshape.fill"
        }
    }
}

struct SidebarView: View {
    @Binding var selection: DashboardTab
    @EnvironmentObject var daemon: DaemonController
    @StateObject private var folder = WatchFolderManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandHeader
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.lg)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(DashboardTab.allCases) { tab in
                    SidebarRow(tab: tab, isSelected: selection == tab) {
                        withAnimation(.easeInOut(duration: 0.18)) { selection = tab }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.sm)

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                if let _ = folder.folderURL {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.Palette.accent)
                        Text(folder.folderName)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                StatusPill(isRunning: daemon.isRunning, mode: daemon.mode)
                if daemon.isRunning {
                    Text("Uptime \(daemon.uptimeString)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.Palette.textMuted)
                }
            }
            .padding(Theme.Spacing.md)
        }
        .frame(width: 220)
        .background(VisualEffectView(material: .sidebar))
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.brandGradient)
                    .frame(width: 36, height: 36)
                    .shadow(color: Theme.Palette.accent.opacity(0.45), radius: 8, y: 2)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Teleport")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("P2P Sync Engine")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.Palette.textMuted)
            }
        }
    }
}

private struct SidebarRow: View {
    let tab: DashboardTab
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)
                Text(tab.title)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                Spacer()
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isSelected
                            ? AnyShapeStyle(Theme.brandGradient)
                            : AnyShapeStyle(hovering ? Color.primary.opacity(0.06) : Color.clear)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
