import SwiftUI
import Foundation

/// Represents a single line emitted by the Rust daemon.
struct LogEntry: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let line: String

    enum Level { case info, success, warn, error, patch, fullFile }

    var level: Level {
        if line.contains("🧩") || line.localizedCaseInsensitiveContains("patch") { return .patch }
        if line.contains("🌐") || line.localizedCaseInsensitiveContains("full file") { return .fullFile }
        if line.contains("✅") { return .success }
        if line.contains("🚨") || line.contains("❌") || line.localizedCaseInsensitiveContains("error") { return .error }
        if line.contains("⚠️") || line.localizedCaseInsensitiveContains("warn") { return .warn }
        return .info
    }
}

/// Modes the daemon can be launched in.
enum DaemonMode: String, Codable {
    case host
    case join
}

/// Owns the lifecycle of the Rust daemon subprocess and exposes
/// observable state (logs, status, stats) to SwiftUI views.
@MainActor
final class DaemonController: ObservableObject {

    /// Single shared instance referenced by AppDelegate, the menu-bar
    /// SwiftUI scene, and the dashboard window's hosted views.
    static let shared = DaemonController()

    // MARK: - Published state

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var mode: DaemonMode? = nil
    @Published private(set) var logs: [LogEntry] = [
        LogEntry(timestamp: Date(), line: "Ready to synchronize.")
    ]
    @Published private(set) var startedAt: Date? = nil
    @Published private(set) var bytesProcessed: Int = 0
    @Published private(set) var patchCount: Int = 0
    @Published private(set) var fullFileCount: Int = 0
    @Published private(set) var resolvedDaemonPath: String? = nil

    /// The passphrase active for the current session. When hosting, this is
    /// the freshly-generated code shown to the user. When joining, this is
    /// what the user typed/pasted. Cleared on stop.
    @Published private(set) var activePassphrase: Passphrase? = nil

    /// Surfaces transient banners ("Reconnecting after sleep…", etc.) at
    /// the top of the dashboard.
    @Published private(set) var statusBanner: String? = nil

    // MARK: - Config

    @AppStorage("teleport.peerIP")  var peerIP: String = "127.0.0.1"
    @AppStorage("teleport.port")    var port: Int = 8080
    @AppStorage("teleport.maxLogs") var maxLogs: Int = 500

    // MARK: - Private

    private var process: Process?
    private var outputPipe: Pipe?
    private let logQueue = DispatchQueue(label: "com.teleport.daemon.logs")

    /// What we were running when sleep hit, so we can offer a one-tap
    /// resume after wake. Hosts can't auto-resume because the passphrase
    /// has rotated; joiners can.
    private struct Snapshot {
        let mode: DaemonMode
        let ip: String?
        let passphrase: Passphrase
    }
    private var preSleepSnapshot: Snapshot?

    init() {
        resolvedDaemonPath = locateDaemonBinary()
    }

    // MARK: - Public API

    /// Start the daemon. For `.host`, `passphrase` is optional — if `nil`
    /// we generate a fresh one. For `.join`, `passphrase` is required and
    /// must match what the host displays.
    func startDaemon(mode: DaemonMode, ip: String? = nil, passphrase: Passphrase? = nil) {
        guard !isRunning else { return }

        guard let folderURL = WatchFolderManager.shared.folderURL else {
            append("❌ No folder selected. Pick a folder to sync from the dashboard before starting.")
            return
        }

        guard FileManager.default.fileExists(atPath: folderURL.path) else {
            append("❌ Selected folder no longer exists: \(folderURL.path)")
            WatchFolderManager.shared.clearFolder()
            return
        }

        guard let daemonPath = locateDaemonBinary() else {
            append("❌ Could not locate `teleport-daemon` binary. Build it via `cargo build` in /daemon, or place it next to Teleport.app.")
            return
        }
        resolvedDaemonPath = daemonPath

        // Resolve passphrase up front so we can display it before launch.
        let resolvedPassphrase: Passphrase
        switch mode {
        case .host:
            resolvedPassphrase = passphrase ?? Passphrase.random()
        case .join:
            guard let p = passphrase else {
                append("❌ A passphrase is required to join. Ask the host for the code shown on its dashboard.")
                return
            }
            resolvedPassphrase = p
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: daemonPath)
        proc.currentDirectoryURL = folderURL

        var args: [String] = [
            "--folder", folderURL.path,
            "--port", String(port),
            "--passphrase", resolvedPassphrase.display,
        ]
        switch mode {
        case .host:
            args.append("host")
        case .join:
            args.append("join")
            args.append(ip ?? peerIP)
        }
        proc.arguments = args

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            let lines = str.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            for line in lines where !line.isEmpty {
                let lineString = String(line)
                Task { @MainActor [weak self] in
                    self?.append(lineString)
                    self?.updateStats(for: lineString)
                }
            }
        }

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleProcessTermination()
            }
        }

        do {
            try proc.run()
            self.process = proc
            self.outputPipe = pipe
            self.isRunning = true
            self.mode = mode
            self.startedAt = Date()
            self.activePassphrase = resolvedPassphrase
            append("📁 Watching folder: \(folderURL.path)")
            switch mode {
            case .host:
                append("🚀 Host listening on port \(port)…")
                append("🔑 Share this passphrase with the joining peer: \(resolvedPassphrase.display)")
            case .join:
                append("🚀 Joining peer at \(ip ?? peerIP):\(port)…")
            }
        } catch {
            append("❌ Failed to start daemon: \(error.localizedDescription)")
        }
    }

    func stopDaemon() {
        guard isRunning else { return }
        process?.terminate()
    }

    /// Called by `AppDelegate` from `NSWorkspace.willSleepNotification`.
    /// Records what we were doing so we can resume on wake (joiners only —
    /// host passphrases are session-scoped) and stops the daemon so the
    /// TCP socket closes cleanly.
    func handleSystemSleep() {
        guard isRunning else { return }
        if let mode = mode, let pp = activePassphrase, mode == .join {
            preSleepSnapshot = Snapshot(mode: mode, ip: peerIP, passphrase: pp)
        }
        append("💤 System going to sleep — stopping daemon.")
        stopDaemon()
    }

    /// Called by `AppDelegate` from `NSWorkspace.didWakeNotification`.
    /// If we have a snapshot of a join session, restart it; otherwise just
    /// surface a banner so the user knows to restart manually.
    func handleSystemWake() {
        guard let snap = preSleepSnapshot else {
            if statusBanner == nil { return }
            statusBanner = nil
            return
        }
        preSleepSnapshot = nil
        statusBanner = "Reconnecting after wake…"
        append("⏰ System woke — reconnecting to \(snap.ip ?? peerIP)…")
        // Brief delay lets the network interface come back up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.startDaemon(mode: snap.mode, ip: snap.ip, passphrase: snap.passphrase)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.statusBanner = nil
            }
        }
    }

    func clearLogs() {
        logs.removeAll()
        append("🧹 Log cleared.")
    }

    func copyLogsToClipboard() {
        let text = logs.map {
            "[\(Self.timeFormatter.string(from: $0.timestamp))] \($0.line)"
        }.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        append("📋 Copied \(logs.count) log lines to clipboard.")
    }

    /// True only when there's a valid folder selected AND we can find the
    /// daemon binary — the two conditions required to start a session.
    var canStart: Bool {
        WatchFolderManager.shared.folderURL != nil && resolvedDaemonPath != nil
    }

    var uptimeString: String {
        guard let startedAt else { return "—" }
        let interval = Int(Date().timeIntervalSince(startedAt))
        let h = interval / 3600
        let m = (interval % 3600) / 60
        let s = interval % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: - Internals

    private func handleProcessTermination() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        outputPipe = nil
        isRunning = false
        mode = nil
        startedAt = nil
        activePassphrase = nil
        append("🛑 Daemon stopped.")
    }

    private func append(_ text: String) {
        let entry = LogEntry(timestamp: Date(), line: text)
        logs.append(entry)
        if logs.count > maxLogs {
            logs.removeFirst(logs.count - maxLogs)
        }
        LogPersistence.shared.append(text)
    }

    /// Parse `(N bytes)` out of daemon log lines so the dashboard counter
    /// reflects actual file payload bytes streamed, not stdout chatter.
    private func updateStats(for line: String) {
        if line.contains("🧩") { patchCount += 1 }
        if line.contains("🌐") { fullFileCount += 1 }
        if let bytes = Self.bytesFromLog(line) {
            bytesProcessed += bytes
        }
    }

    private static let byteCountRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\((\d+)\s*bytes\)"#)
    }()

    private static func bytesFromLog(_ line: String) -> Int? {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = byteCountRegex.firstMatch(in: line, range: range),
              let r = Range(m.range(at: 1), in: line)
        else { return nil }
        return Int(line[r])
    }

    /// Resolution order:
    /// 1. Inside the .app bundle (`Contents/MacOS/teleport-daemon`)
    /// 2. Adjacent to the executable (sibling file)
    /// 3. `$PATH` lookup via `/usr/bin/env which`
    /// 4. Common dev paths relative to the workspace root
    private func locateDaemonBinary() -> String? {
        let fm = FileManager.default

        // 1) Bundled inside the app
        if let bundled = Bundle.main.url(forResource: "teleport-daemon", withExtension: nil)?.path,
           fm.isExecutableFile(atPath: bundled) {
            return bundled
        }

        // 2) Sibling of the running executable
        let execURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let sibling = execURL.deletingLastPathComponent().appendingPathComponent("teleport-daemon").path
        if fm.isExecutableFile(atPath: sibling) { return sibling }

        // 3) PATH
        if let path = which("teleport-daemon") { return path }

        // 4) Dev fallbacks
        let candidates = [
            "\(NSHomeDirectory())/Desktop/Project/Teleport/daemon/target/release/teleport-daemon",
            "\(NSHomeDirectory())/Desktop/Project/Teleport/daemon/target/debug/teleport-daemon",
            fm.currentDirectoryPath + "/daemon/target/release/teleport-daemon",
            fm.currentDirectoryPath + "/daemon/target/debug/teleport-daemon"
        ]
        for c in candidates where fm.isExecutableFile(atPath: c) { return c }
        return nil
    }

    private func which(_ binary: String) -> String? {
        let proc = Process()
        proc.launchPath = "/usr/bin/env"
        proc.arguments = ["which", binary]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let s = String(data: data, encoding: .utf8) {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, FileManager.default.isExecutableFile(atPath: trimmed) {
                    return trimmed
                }
            }
        } catch {}
        return nil
    }
}
