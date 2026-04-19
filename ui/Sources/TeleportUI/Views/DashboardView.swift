import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var daemon: DaemonController
    @StateObject private var folder = WatchFolderManager.shared
    @State private var ipDraft: String = ""
    @State private var now: Date = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                header

                if folder.folderURL == nil {
                    folderEmptyState
                } else {
                    folderCard
                    statsGrid
                    HStack(alignment: .top, spacing: Theme.Spacing.md) {
                        controlPanel
                            .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)
                        sessionInfoPanel
                    }
                    recentActivity
                }
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(VisualEffectView(material: .underWindowBackground))
        .onAppear { ipDraft = daemon.peerIP }
        .onReceive(ticker) { now = $0 }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Dashboard")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Real-time peer-to-peer file synchronization")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Palette.textMuted)
            }
            Spacer()
            StatusPill(isRunning: daemon.isRunning, mode: daemon.mode)
        }
    }

    /// First-run onboarding: prompts the user to pick a folder before they
    /// can start a session. The whole "control surface" stays hidden until
    /// a folder is selected — a hard requirement for the daemon to work.
    private var folderEmptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(Theme.brandGradient.opacity(0.15))
                    .frame(width: 110, height: 110)
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(Theme.brandGradient)
            }
            VStack(spacing: 6) {
                Text("Choose a folder to sync")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("Teleport watches the folder you pick and streams every change to your peer in real time. Pick a project root, a Docs folder, anything.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Palette.textMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            PrimaryButton("Choose Folder…", systemImage: "folder.fill.badge.plus") {
                folder.pickFolder()
            }
            .frame(maxWidth: 280)

            if !folder.recentFolders.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .tracking(0.7)
                        .foregroundStyle(Theme.Palette.textMuted)
                    ForEach(folder.recentFolders, id: \.self) { url in
                        Button {
                            folder.setFolder(url)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(Theme.Palette.textMuted)
                                Text(url.lastPathComponent)
                                    .font(.system(size: 12, weight: .semibold))
                                Text(url.path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.Palette.textMuted)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Theme.Palette.surfaceAlt.opacity(0.5))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 460)
                .padding(.top, Theme.Spacing.sm)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.xl)
        .card(padding: Theme.Spacing.lg)
    }

    /// Compact card showing the active folder, with quick actions.
    private var folderCard: some View {
        HStack(spacing: Theme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.brandGradient)
                    .frame(width: 44, height: 44)
                Image(systemName: "folder.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.folderName)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(folder.displayPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            HStack(spacing: 6) {
                Button {
                    folder.revealInFinder()
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")

                Button {
                    folder.pickFolder()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .help("Change folder")
                .disabled(daemon.isRunning)
            }
            .font(.system(size: 14))
            .foregroundStyle(Theme.Palette.accent)
        }
        .card(padding: Theme.Spacing.md)
    }

    private var statsGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 160), spacing: Theme.Spacing.md)]
        return LazyVGrid(columns: columns, spacing: Theme.Spacing.md) {
            StatTile(
                title: "Uptime",
                value: daemon.isRunning ? daemon.uptimeString : "—",
                systemImage: "clock.fill",
                tint: Theme.Palette.accent
            )
            StatTile(
                title: "Patches",
                value: "\(daemon.patchCount)",
                systemImage: "puzzlepiece.extension.fill",
                tint: .cyan
            )
            StatTile(
                title: "Full Files",
                value: "\(daemon.fullFileCount)",
                systemImage: "doc.fill",
                tint: Theme.Palette.accentAlt
            )
            StatTile(
                title: "Bytes Streamed",
                value: byteString(daemon.bytesProcessed),
                systemImage: "arrow.up.arrow.down",
                tint: Theme.Palette.success
            )
        }
    }

    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Connection")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.Palette.textMuted)

            VStack(alignment: .leading, spacing: 8) {
                Text("Peer IP Address")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textMuted)
                TextField("127.0.0.1", text: $ipDraft, onCommit: {
                    daemon.peerIP = ipDraft
                })
                .textFieldStyle(.roundedBorder)
                .disabled(daemon.isRunning)
                .onChange(of: ipDraft) { _, newValue in
                    daemon.peerIP = newValue
                }
            }

            if !daemon.isRunning {
                VStack(spacing: 10) {
                    PrimaryButton("Start Host", systemImage: "antenna.radiowaves.left.and.right") {
                        daemon.startDaemon(mode: .host)
                    }
                    SecondaryButton("Join Peer", systemImage: "link") {
                        daemon.startDaemon(mode: .join, ip: ipDraft)
                    }
                }
            } else {
                SecondaryButton("Stop Session", systemImage: "stop.fill", role: .destructive) {
                    daemon.stopDaemon()
                }
            }
        }
        .card(padding: Theme.Spacing.md)
    }

    private var sessionInfoPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Session")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.Palette.textMuted)

            InfoRow(
                label: "Mode",
                value: daemon.mode.map { $0 == .host ? "Host" : "Join" } ?? "Idle"
            )
            InfoRow(
                label: "Started",
                value: daemon.startedAt.map { Self.dateFormatter.string(from: $0) } ?? "—"
            )
            InfoRow(
                label: "Port",
                value: "\(daemon.port)",
                monospaced: true
            )
            InfoRow(
                label: "Daemon Binary",
                value: daemon.resolvedDaemonPath ?? "Not found",
                monospaced: true
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Theme.Spacing.md)
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text("Recent Activity")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Palette.textMuted)
                Spacer()
                Text("\(daemon.logs.count) entries")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textMuted)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(daemon.logs.suffix(8).reversed()) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Text(DaemonController.timeFormatter.string(from: entry.timestamp))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.Palette.textMuted)
                            .frame(width: 64, alignment: .leading)
                        Text(entry.line)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(color(for: entry.level))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 6)
                    Divider().opacity(0.4)
                }
            }
            .card(padding: Theme.Spacing.sm)
        }
    }

    // MARK: - Helpers

    private func color(for level: LogEntry.Level) -> Color {
        switch level {
        case .info:     return .primary
        case .success:  return Theme.Palette.success
        case .warn:     return Theme.Palette.warning
        case .error:    return Theme.Palette.danger
        case .patch:    return .cyan
        case .fullFile: return Theme.Palette.accent
        }
    }

    private func byteString(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .binary)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm:ss"
        return f
    }()
}
