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

/// Thread-safe stdout-line accumulator used by the daemon pipe handler.
/// Reads come in on an arbitrary background thread, so we serialise all
/// access through an internal lock and return whole lines to the caller.
final class LineBuffer: @unchecked Sendable {
    private var carry = Data()
    private let lock = NSLock()

    /// Feed bytes; returns any newly-completed lines (without trailing newlines).
    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        carry.append(data)
        guard let lastNL = carry.lastIndex(where: { $0 == 0x0A || $0 == 0x0D }) else { return [] }
        let completeRange = carry.startIndex..<carry.index(after: lastNL)
        let chunk = carry.subdata(in: completeRange)
        carry.removeSubrange(completeRange)
        guard let str = String(data: chunk, encoding: .utf8) else { return [] }
        return str
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map(String.init)
            .filter { !$0.isEmpty }
    }
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

    /// Whole-second uptime, refreshed by an internal timer while the
    /// daemon is running. Lives here (not in views) so every observer —
    /// dashboard, sidebar, menu bar — re-renders in lockstep instead of
    /// each one having to wire up its own ticker.
    @Published private(set) var uptimeSeconds: Int = 0

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
    private var uptimeTimer: Timer?

    /// Lines coming off the daemon pipe accumulate here and get drained
    /// to the main actor on a ~16 ms tick. Without this, a noisy initial
    /// sync (1k+ files) hits the SwiftUI graph at ~1 kHz and every
    /// view that observes `logs` re-renders on every line.
    private var pendingLines: [String] = []
    private var flushScheduled = false

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

        // SECURITY: pass the passphrase via an environment variable, never
        // via argv. On macOS, argv is readable by any user via `ps -ef` /
        // Activity Monitor / `sysctl kern.proc.args`, while env vars are
        // gated to the same uid. The daemon strips the variable from its
        // own process before forking anything.
        var env = ProcessInfo.processInfo.environment
        env["TELEPORT_PASSPHRASE"] = resolvedPassphrase.display
        proc.environment = env

        var args: [String] = [
            "--folder", folderURL.path,
            "--port", String(port),
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

        // Buffer raw bytes across reads — a single `availableData` call may
        // hand us a partial UTF-8 sequence at the boundary or split a line
        // mid-way. Holding the tail until we see a newline prevents both
        // garbled glyphs and "1/2 of a log line" entries.
        // Reference type so the closure captures a stable identity (Swift 6
        // strict-concurrency disallows mutating captured `var`s).
        let carry = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let lines = carry.append(data)
            guard !lines.isEmpty else { return }
            self?.enqueueLines(lines)
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
            self.startUptimeTimer()
            append("📁 Watching folder: \(folderURL.path)")
            switch mode {
            case .host:
                append("🚀 Host listening on port \(port). Passphrase shown in dashboard.")
                // SECURITY: the passphrase itself is never written to logs
                // (memory or disk). It only lives in `activePassphrase` for
                // the UI to render and gets cleared on stop.
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
        guard isRunning else { return "—" }
        let interval = uptimeSeconds
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
        stopUptimeTimer()
        append("🛑 Daemon stopped.")
    }

    /// Starts a 1-second timer that publishes `uptimeSeconds`. Scheduled
    /// on the main run loop in `.common` modes so it keeps ticking even
    /// while the user is dragging the window or scrolling logs.
    private func startUptimeTimer() {
        stopUptimeTimer()
        uptimeSeconds = 0
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let started = self.startedAt else { return }
                self.uptimeSeconds = Int(Date().timeIntervalSince(started))
            }
        }
        // `.common` ensures the timer fires during event-tracking modes
        // too (window drag, menu open, scroll). `.default` alone freezes.
        RunLoop.main.add(timer, forMode: .common)
        uptimeTimer = timer
    }

    private func stopUptimeTimer() {
        uptimeTimer?.invalidate()
        uptimeTimer = nil
        uptimeSeconds = 0
    }

    private func append(_ text: String) {
        let safe = Self.redact(text)
        let entry = LogEntry(timestamp: Date(), line: safe)
        logs.append(entry)
        if logs.count > maxLogs {
            logs.removeFirst(logs.count - maxLogs)
        }
        LogPersistence.shared.append(safe)
    }

    /// Called from the pipe-reader background thread. Buffers lines and
    /// schedules a single coalesced flush to the main actor instead of
    /// posting one Task per line — under heavy load (initial sync of a
    /// large repo) the per-line `Task @MainActor` model used to peg the
    /// dispatcher and re-render every observer for every line.
    private nonisolated func enqueueLines(_ lines: [String]) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.pendingLines.append(contentsOf: lines)
            self.scheduleFlush()
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        // ~16 ms ≈ one display frame: imperceptible UI delay, but lets
        // bursts of 50–500 lines collapse into a single state mutation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            self?.flushPendingLines()
        }
    }

    private func flushPendingLines() {
        flushScheduled = false
        guard !pendingLines.isEmpty else { return }
        let batch = pendingLines
        pendingLines.removeAll(keepingCapacity: true)

        let now = Date()
        var newEntries: [LogEntry] = []
        newEntries.reserveCapacity(batch.count)
        for raw in batch {
            let safe = Self.redact(raw)
            newEntries.append(LogEntry(timestamp: now, line: safe))
            updateStats(for: safe)
            LogPersistence.shared.append(safe)
        }
        logs.append(contentsOf: newEntries)
        if logs.count > maxLogs {
            logs.removeFirst(logs.count - maxLogs)
        }
    }

    /// Defence-in-depth log scrubber. The daemon was changed to never print
    /// the passphrase, but if a future change ever leaks it, redact it
    /// before it can hit the on-disk log file or the clipboard.
    private static func redact(_ line: String) -> String {
        guard let pp = DaemonController.shared.activePassphrase else { return line }
        let secret = pp.display
        guard !secret.isEmpty, line.contains(secret) else { return line }
        return line.replacingOccurrences(of: secret, with: "[REDACTED]")
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
