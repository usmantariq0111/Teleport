import SwiftUI
import Foundation

class DaemonController: ObservableObject {
    @Published var isRunning = false
    @Published var logs: [String] = ["Ready to synchronize."]
    
    private var process: Process?
    private var outputPipe: Pipe?
    
    func appendLog(_ text: String) {
        DispatchQueue.main.async {
            self.logs.append(text)
            // Keep the last 150 lines to save memory
            if self.logs.count > 150 {
                self.logs.removeFirst()
            }
        }
    }
    
    func startDaemon(mode: String, ip: String = "") {
        guard !isRunning else { return }
        
        var daemonPath = ""
        if let bundlePath = Bundle.main.url(forResource: "teleport-daemon", withExtension: nil)?.path {
            daemonPath = bundlePath
        } else {
            daemonPath = NSHomeDirectory() + "/Desktop/Project/Teleport/daemon/target/debug/teleport-daemon"
        }
        
        if !FileManager.default.fileExists(atPath: daemonPath) {
            appendLog("❌ Error: Rust binary not found at \(daemonPath)")
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
                let lines = str.split(separator: "\n").map { String($0) }
                for line in lines where !line.isEmpty {
                    self?.appendLog(line)
                }
            }
        }
        
        do {
            try process?.run()
            DispatchQueue.main.async {
                self.isRunning = true
                self.appendLog(mode == "host" ? "🚀 Host listening on 8080..." : "🚀 Joining \(ip)...")
            }
        } catch {
            DispatchQueue.main.async {
                self.appendLog("❌ Failed to start: \(error.localizedDescription)")
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
            self.appendLog("🛑 Daemon stopped.")
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var daemon: DaemonController
    @State private var ipAddress = "127.0.0.1"
    
    var body: some View {
        HStack(spacing: 0) {
            // Left Panel: Controls
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Teleport")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                    Text("Ultra-fast P2P Sync Engine")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                VStack(alignment: .leading, spacing: 16) {
                    Text("Configuration")
                        .font(.headline)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Peer IP Address")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("127.0.0.1", text: $ipAddress)
                            .textFieldStyle(.roundedBorder)
                            .disabled(daemon.isRunning)
                    }
                }
                
                Spacer()
                
                // Status Indicator
                HStack {
                    Circle()
                        .fill(daemon.isRunning ? Color.green : Color.red)
                        .frame(width: 12, height: 12)
                        .shadow(color: daemon.isRunning ? .green : .red, radius: daemon.isRunning ? 8 : 2)
                        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: daemon.isRunning)
                    
                    Text(daemon.isRunning ? "Connected" : "Disconnected")
                        .font(.headline)
                        .foregroundColor(daemon.isRunning ? .green : .secondary)
                }
                .padding(.bottom, 8)
                
                // Action Buttons
                if !daemon.isRunning {
                    VStack(spacing: 12) {
                        Button(action: { daemon.startDaemon(mode: "host") }) {
                            Text("Start Host")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        
                        Button(action: { daemon.startDaemon(mode: "join", ip: ipAddress) }) {
                            Text("Join Peer")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                } else {
                    Button(action: { daemon.stopDaemon() }) {
                        Text("Stop Session")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .padding(30)
            .frame(width: 320)
            .background(Material.thin)
            
            Divider()
            
            // Right Panel: Live Terminal
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("LIVE RUST LOGS")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                    Spacer()
                }
                .padding()
                .background(Color.black.opacity(0.4))
                
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(daemon.logs.enumerated()), id: \.offset) { index, log in
                                Text(log)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(logColor(log))
                                    .id(index)
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: daemon.logs.count) { _ in
                        withAnimation {
                            proxy.scrollTo(daemon.logs.count - 1, anchor: .bottom)
                        }
                    }
                }
                .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
            }
            .frame(minWidth: 400, maxWidth: .infinity)
        }
        .frame(minWidth: 700, minHeight: 450)
        .ignoresSafeArea()
    }
    
    private func logColor(_ log: String) -> Color {
        if log.contains("🧩 Received patch") { return .cyan }
        if log.contains("🌐 Received full file") { return .blue }
        if log.contains("✅") { return .green }
        if log.contains("🚨") || log.contains("❌") || log.contains("Error") { return .red }
        if log.contains("⚠️") { return .yellow }
        return .primary
    }
}

@main
struct TeleportApp: App {
    @StateObject private var daemon = DaemonController()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(daemon)
                .background(VisualEffectView().ignoresSafeArea())
        }
        .windowStyle(.hiddenTitleBar)
        
        MenuBarExtra("Teleport", systemImage: daemon.isRunning ? "bolt.horizontal.fill" : "bolt.horizontal") {
            Button("Open Dashboard") {
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows {
                    // Ignore the tiny menu bar window itself
                    if window.className != "NSStatusBarWindow" {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
            }
            
            Divider()
            
            Button(daemon.isRunning ? "Stop Daemon" : "Start Host") {
                if daemon.isRunning {
                    daemon.stopDaemon()
                } else {
                    daemon.startDaemon(mode: "host")
                }
            }
            Divider()
            Button("Quit Teleport") {
                daemon.stopDaemon()
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

// Helper for Native Glass Blur
struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .sidebar
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
