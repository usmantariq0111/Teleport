import Foundation

/// Append-only log writer rooted at `~/Library/Logs/Teleport/teleport.log`.
///
/// Why not OSLog? OSLog is excellent for system-integrated diagnostics, but
/// the daemon already emits human-friendly text logs that the user wants
/// to read directly (Console.app rendering of OSLog metadata is noisy and
/// the strings get redacted in release builds). A plain rotating file
/// better matches the existing UX.
///
/// Rotation policy: when the active file passes `maxBytes`, it's renamed
/// to `teleport.log.1` and a fresh file is started. We keep one rotated
/// file. That's enough for support / "what happened last night?" debugging
/// without unbounded growth.
final class LogPersistence {

    static let shared = LogPersistence()

    private let queue = DispatchQueue(label: "com.teleport.log.persist")
    private let logURL: URL
    private let archiveURL: URL
    private let maxBytes: UInt64 = 5 * 1024 * 1024  // 5 MB

    /// One persistent handle for the active log. Re-opened only after a
    /// rotation. Without this we open + seek-to-end + close per log line
    /// (4 syscalls), which dominates write throughput during initial sync
    /// of a large repo.
    private var handle: FileHandle?
    /// Tracked locally so we don't have to `stat()` after every write
    /// to know when we've crossed the rotation threshold.
    private var bytesWritten: UInt64 = 0

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.timeZone = TimeZone.current
        return f
    }()

    private init() {
        let fm = FileManager.default
        let logsDir = fm.urls(for: .libraryDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Logs/Teleport", isDirectory: true)
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        self.logURL = logsDir.appendingPathComponent("teleport.log")
        self.archiveURL = logsDir.appendingPathComponent("teleport.log.1")
        openHandle()
        write(line: "==== Teleport launched at \(Self.timeFormatter.string(from: Date())) ====")
    }

    deinit {
        try? handle?.close()
    }

    /// Append one line. Non-blocking; ordered. Errors are swallowed because
    /// log persistence must never crash the host process.
    func append(_ line: String) {
        queue.async { [self] in
            self.write(line: line)
        }
    }

    /// User-facing: where the log lives, suitable for "Reveal in Finder".
    var fileURL: URL { logURL }

    /// Pretty path used in the UI.
    var displayPath: String {
        let home = NSHomeDirectory()
        let path = logURL.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Synchronously read the whole on-disk log — both the active file and
    /// the rotated archive. Used by the "Open Log" / share button.
    func snapshot() -> String {
        var pieces: [String] = []
        if let archived = try? String(contentsOf: archiveURL, encoding: .utf8) {
            pieces.append(archived)
        }
        if let active = try? String(contentsOf: logURL, encoding: .utf8) {
            pieces.append(active)
        }
        return pieces.joined()
    }

    // MARK: - Private

    private func write(line: String) {
        let stamped = "[\(Self.timeFormatter.string(from: Date()))] \(line)\n"
        guard let data = stamped.data(using: .utf8) else { return }

        if handle == nil { openHandle() }
        guard let h = handle else { return }
        do {
            try h.write(contentsOf: data)
            bytesWritten &+= UInt64(data.count)
            if bytesWritten > maxBytes {
                rotate()
            }
        } catch {
            // Re-open on next write — handle may be stale (e.g. file got
            // moved out from under us by an external tool).
            try? handle?.close()
            handle = nil
        }
    }

    private func openHandle() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
            bytesWritten = 0
        } else if let attrs = try? fm.attributesOfItem(atPath: logURL.path),
                  let size = attrs[.size] as? UInt64 {
            bytesWritten = size
        }
        do {
            let h = try FileHandle(forWritingTo: logURL)
            try h.seekToEnd()
            handle = h
        } catch {
            handle = nil
        }
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: archiveURL)
        try? fm.moveItem(at: logURL, to: archiveURL)
        bytesWritten = 0
        openHandle()
    }
}
