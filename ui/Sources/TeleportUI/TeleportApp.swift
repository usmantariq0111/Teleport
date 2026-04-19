import SwiftUI
import Foundation

class DaemonController: ObservableObject {
    @Published var isRunning = false
    @Published var lastLog = "Waiting to start..."
    
    private var process: Process?
    private var outputPipe: Pipe?
    
    func startDaemon(mode: String, ip: String = "") {
        guard !isRunning else { return }
        
        // Find the absolute path to our compiled Rust binary
        var daemonPath = ""
        
        // Check if we are running inside a bundled .app (Production)
        if let bundlePath = Bundle.main.url(forResource: "teleport-daemon", withExtension: nil)?.path {
            daemonPath = bundlePath
        } else {
            // Fallback to local dev path
            daemonPath = NSHomeDirectory() + "/Desktop/Project/Teleport/daemon/target/debug/teleport-daemon"
        }
        
        if !FileManager.default.fileExists(atPath: daemonPath) {
            self.lastLog = "Error: Rust binary not found at \(daemonPath)"
            return
        }
        
        process = Process()
        process?.executableURL = URL(fileURLWithPath: daemonPath)
        
        if mode == "host" {
            process?.arguments = ["host"]
        } else {
            process?.arguments = ["join", ip]
        }
        
        outputPipe = Pipe()
        process?.standardOutput = outputPipe
        process?.standardError = outputPipe
        
        outputPipe?.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let str = String(data: data, encoding: .utf8) {
                // Split by newline and get the last valid line to show in UI
                let lines = str.split(separator: "\n").map { String($0) }
                if let last = lines.last, !last.isEmpty {
                    DispatchQueue.main.async {
                        self?.lastLog = last
                    }
                }
            }
        }
        
        do {
            try process?.run()
            DispatchQueue.main.async {
                self.isRunning = true
                self.lastLog = mode == "host" ? "📡 Host listening on 8080..." : "📡 Joining \(ip)..."
            }
        } catch {
            DispatchQueue.main.async {
                self.lastLog = "❌ Failed to start: \(error.localizedDescription)"
            }
        }
    }
    
    func stopDaemon() {
        process?.terminate()
        process = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        DispatchQueue.main.async {
            self.isRunning = false
            self.lastLog = "Stopped."
        }
    }
}

@main
struct TeleportApp: App {
    @StateObject private var daemon = DaemonController()
    @State private var ipAddress = "127.0.0.1"
    
    var body: some Scene {
        MenuBarExtra("Teleport", systemImage: daemon.isRunning ? "bolt.horizontal.fill" : "bolt.horizontal") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Teleport P2P Sync")
                    .font(.headline)
                
                Text(daemon.lastLog)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(daemon.isRunning ? .green : .secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.black.opacity(0.1))
                    .cornerRadius(4)
                
                Divider()
                
                if !daemon.isRunning {
                    Button(action: {
                        daemon.startDaemon(mode: "host")
                    }) {
                        Label("Start Host", systemImage: "network")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Button(action: {
                        daemon.startDaemon(mode: "join", ip: ipAddress)
                    }) {
                        Label("Join Localhost", systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(action: {
                        daemon.stopDaemon()
                    }) {
                        Label("Stop Session", systemImage: "stop.circle")
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.bordered)
                }
                
                Divider()
                
                Button("Quit Teleport") {
                    daemon.stopDaemon()
                    NSApplication.shared.terminate(nil)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding()
            .frame(width: 250)
        }
        .menuBarExtraStyle(.window)
    }
}
