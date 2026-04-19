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

    // MARK: - Config

    @AppStorage("teleport.peerIP")  var peerIP: String = "127.0.0.1"
    @AppStorage("teleport.maxLogs") var maxLogs: Int = 500

    // MARK: - Private

    private var process: Process?
    private var outputPipe: Pipe?
    private let logQueue = DispatchQueue(label: "com.teleport.daemon.logs")

    init() {
        resolvedDaemonPath = locateDaemonBinary()
    }

    // MARK: - Public API

    func startDaemon(mode: DaemonMode, ip: String? = nil) {
        guard !isRunning else { return }

        guard let daemonPath = locateDaemonBinary() else {
            append("❌ Could not locate `teleport-daemon` binary. Build it via `cargo build` in /daemon, or place it next to Teleport.app.")
            return
        }
        resolvedDaemonPath = daemonPath

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: daemonPath)

        switch mode {
        case .host:
            proc.arguments = ["host"]
        case .join:
            proc.arguments = ["join", ip ?? peerIP]
        }

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
                    self?.updateStats(for: lineString, byteCount: data.count)
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
            switch mode {
            case .host: append("🚀 Host listening on port 8080…")
            case .join: append("🚀 Joining peer at \(ip ?? peerIP)…")
            }
        } catch {
            append("❌ Failed to start daemon: \(error.localizedDescription)")
        }
    }

    func stopDaemon() {
        guard isRunning else { return }
        process?.terminate()
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
        append("🛑 Daemon stopped.")
    }

    private func append(_ text: String) {
        let entry = LogEntry(timestamp: Date(), line: text)
        logs.append(entry)
        if logs.count > maxLogs {
            logs.removeFirst(logs.count - maxLogs)
        }
    }

    private func updateStats(for line: String, byteCount: Int) {
        bytesProcessed += byteCount
        if line.contains("🧩") { patchCount += 1 }
        if line.contains("🌐") { fullFileCount += 1 }
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
