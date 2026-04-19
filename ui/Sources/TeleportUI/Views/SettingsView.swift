import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var daemon: DaemonController
    @StateObject private var folder = WatchFolderManager.shared
    @AppStorage("teleport.autoScroll")  private var autoScroll: Bool = true
    @AppStorage("teleport.maxLogs")     private var maxLogs: Int = 500
    @AppStorage("teleport.peerIP")      private var peerIP: String = "127.0.0.1"
    @AppStorage("teleport.port")        private var port: Int = 8080

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text("Settings")
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                section("Sync Folder") {
                    VStack(alignment: .leading, spacing: 12) {
                        if let _ = folder.folderURL {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(Theme.Palette.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(folder.folderName)
                                        .font(.system(size: 14, weight: .semibold))
                                    Text(folder.displayPath)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Theme.Palette.textMuted)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                            }
                            HStack(spacing: 8) {
                                SecondaryButton("Change…", systemImage: "folder.fill") {
                                    folder.pickFolder()
                                }
                                .disabled(daemon.isRunning)
                                SecondaryButton("Reveal in Finder", systemImage: "arrow.up.right.square") {
                                    folder.revealInFinder()
                                }
                            }
                        } else {
                            Text("No folder selected.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.Palette.textMuted)
                            SecondaryButton("Choose Folder…", systemImage: "folder.fill.badge.plus") {
                                folder.pickFolder()
                            }
                        }

                        if !folder.recentFolders.isEmpty {
                            Divider().padding(.vertical, 4)
                            Text("RECENT")
                                .font(.system(size: 10, weight: .heavy, design: .rounded))
                                .tracking(0.5)
                                .foregroundStyle(Theme.Palette.textMuted)
                            ForEach(folder.recentFolders, id: \.self) { url in
                                Button {
                                    folder.setFolder(url)
                                } label: {
                                    HStack {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Theme.Palette.textMuted)
                                        Text(url.lastPathComponent)
                                            .font(.system(size: 12, weight: .semibold))
                                        Text(url.path)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(Theme.Palette.textMuted)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                    }
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                                .disabled(daemon.isRunning || url.path == folder.folderURL?.path)
                            }
                        }
                    }
                }

                section("Network") {
                    VStack(alignment: .leading, spacing: 12) {
                        labeledField("Default Peer IP", binding: $peerIP, placeholder: "127.0.0.1")
                            .disabled(daemon.isRunning)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Port")
                                .font(.system(size: 12, weight: .semibold))
                            TextField("8080", value: $port, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                                .disabled(daemon.isRunning)
                        }
                    }
                }

                section("Logging") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Auto-scroll log viewer", isOn: $autoScroll)
                            .toggleStyle(.switch)
                            .tint(Theme.Palette.accent)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Maximum log entries")
                                    .font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text("\(maxLogs)")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Theme.Palette.textMuted)
                            }
                            Slider(value: Binding(
                                get: { Double(maxLogs) },
                                set: { maxLogs = Int($0) }
                            ), in: 100...5000, step: 100)
                            .tint(Theme.Palette.accent)
                        }
                    }
                }

                section("Security") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(Theme.Palette.success)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("End-to-end encrypted")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Noise NNpsk0 (Curve25519 · ChaCha20-Poly1305 · BLAKE2s)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.Palette.textMuted)
                            }
                            Spacer()
                        }
                        Text("Each session uses a one-time passphrase shared out-of-band. Wrong passphrase, wrong peer — connections are rejected at handshake.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                section("Diagnostics") {
                    VStack(alignment: .leading, spacing: 8) {
                        InfoRow(label: "Daemon Binary",
                                value: daemon.resolvedDaemonPath ?? "Not found",
                                monospaced: true)
                        InfoRow(label: "Working Directory",
                                value: FileManager.default.currentDirectoryPath,
                                monospaced: true)
                        InfoRow(label: "App Version", value: Self.appVersion)
                        InfoRow(label: "macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
                    }
                }

                section("About") {
                    HStack(alignment: .top, spacing: 16) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Theme.brandGradient)
                                .frame(width: 64, height: 64)
                                .shadow(color: Theme.Palette.accent.opacity(0.45), radius: 10, y: 4)
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 30, weight: .black))
                                .foregroundStyle(.white)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Teleport")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                            Text("Native macOS P2P sync engine. Built with Rust + SwiftUI.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.Palette.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Version \(Self.appVersion)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.Palette.textMuted)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(VisualEffectView(material: .underWindowBackground))
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(Theme.Palette.textMuted)
            content().card(padding: Theme.Spacing.md)
        }
    }

    private func labeledField(_ label: String, binding: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
            TextField(placeholder, text: binding)
                .textFieldStyle(.roundedBorder)
        }
    }

    private static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
