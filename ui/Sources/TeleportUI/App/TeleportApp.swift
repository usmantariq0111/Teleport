import SwiftUI

@main
struct TeleportApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var daemon = DaemonController()

    var body: some Scene {
        WindowGroup(id: AppDelegate.dashboardWindowID) {
            RootView()
                .environmentObject(daemon)
                .frame(minWidth: 920, minHeight: 580)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1080, height: 660)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(daemon)
        } label: {
            Image(systemName: daemon.isRunning ? "bolt.horizontal.fill" : "bolt.horizontal")
        }
        .menuBarExtraStyle(.window)
    }
}
