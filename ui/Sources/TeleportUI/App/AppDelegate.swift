import SwiftUI
import AppKit

/// Owns the dashboard window directly via AppKit instead of SwiftUI's
/// `WindowGroup` + `openWindow(id:)`. The SwiftUI route is unreliable
/// when triggered from inside a `MenuBarExtra` (Apple bug across multiple
/// SDKs) — clicks frequently do nothing, or open a window that never
/// becomes key. Hosting `RootView` inside an `NSHostingController` and
/// driving an `NSWindow` ourselves sidesteps the problem entirely.
///
/// We also handle the activation-policy dance:
///   • Launch as `.accessory`  → menu-bar utility, no Dock icon.
///   • Open dashboard           → promote to `.regular`, bring to front.
///   • Close dashboard          → demote back to `.accessory`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Captured during `init` so we never have to look up the delegate
    /// through `NSApp.delegate` — which on macOS 14+ is often a SwiftUI
    /// proxy that *forwards* to us, not us. Trusting the cast crashed
    /// the app on macOS 26 (`fatalError` in the menu-bar button action).
    static private(set) var shared: AppDelegate!

    private var dashboardWindow: NSWindow?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        registerSleepWakeObservers()
    }

    // MARK: - Sleep / wake

    /// macOS posts these notifications on `NSWorkspace.shared.notificationCenter`,
    /// not the default center. Easy to miss.
    private func registerSleepWakeObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self,
                       selector: #selector(systemWillSleep(_:)),
                       name: NSWorkspace.willSleepNotification,
                       object: nil)
        nc.addObserver(self,
                       selector: #selector(systemDidWake(_:)),
                       name: NSWorkspace.didWakeNotification,
                       object: nil)
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        // Stop the daemon so its TCP socket closes cleanly. Otherwise a
        // hanging connection wakes up half-broken on the other side, the
        // peer can't tell we left, and the next event quietly drops.
        DaemonController.shared.handleSystemSleep()
    }

    @objc private func systemDidWake(_ notification: Notification) {
        DaemonController.shared.handleSystemWake()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menu-bar app stays alive after the dashboard closes.
        false
    }

    // MARK: - Dashboard window

    func showDashboard() {
        if dashboardWindow == nil {
            let root = RootView()
                .environmentObject(DaemonController.shared)
            let hosting = NSHostingController(rootView: root)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1080, height: 660),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = hosting
            window.title = "Teleport"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.minSize = NSSize(width: 920, height: 580)
            window.setFrameAutosaveName("TeleportDashboard")
            window.isReleasedWhenClosed = false
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.center()
            window.delegate = self

            dashboardWindow = window
        }

        // Promote so the window can take focus, then activate.
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.dashboardWindow?.makeKeyAndOrderFront(nil)
            self?.dashboardWindow?.orderFrontRegardless()
        }
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === dashboardWindow else { return }
        // Brief delay avoids a Dock-icon flicker during the close animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
