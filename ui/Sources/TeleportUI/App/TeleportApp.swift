import SwiftUI

@main
struct TeleportApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var daemon = DaemonController.shared

    var body: some Scene {
        // The dashboard window is created and managed by AppDelegate
        // using NSHostingController + NSWindow (see AppDelegate.swift).
        // SwiftUI only owns the MenuBarExtra here.
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(daemon)
        } label: {
            Image(systemName: daemon.isRunning ? "bolt.horizontal.fill" : "bolt.horizontal")
        }
        .menuBarExtraStyle(.window)
    }
}
