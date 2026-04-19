import SwiftUI
import AppKit
import Combine

/// Responsible for the activation-policy dance that makes a SwiftUI
/// `MenuBarExtra` app behave correctly when opening a regular window.
///
/// macOS will not show or focus a window for a `LSUIElement` / `.accessory`
/// app. The naive workaround is to permanently call
/// `NSApp.setActivationPolicy(.regular)`, which works but leaves a stale
/// Dock icon hanging around forever.
///
/// Instead, we promote to `.regular` only while the dashboard window is
/// visible, and demote back to `.accessory` (menu-bar only, no Dock icon)
/// once it closes. The result: a clean menu-bar utility that pops a real
/// window with full focus, then hides itself completely again.
final class AppDelegate: NSObject, NSApplicationDelegate {

    static let dashboardWindowID = "dashboard"

    private var cancellables = Set<AnyCancellable>()
    private var dashboardWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start as a clean menu-bar utility — no Dock icon, no app-switcher entry.
        NSApp.setActivationPolicy(.accessory)

        NotificationCenter.default
            .publisher(for: NSWindow.willCloseNotification)
            .sink { [weak self] note in
                guard let window = note.object as? NSWindow,
                      window === self?.dashboardWindow else { return }
                self?.dashboardWindow = nil
                self?.demoteToAccessory()
            }
            .store(in: &cancellables)
    }

    /// Called by the menu-bar action. Opens (or focuses) the dashboard.
    func showDashboard(using openWindow: OpenWindowAction) {
        promoteToRegular()
        openWindow(id: Self.dashboardWindowID)

        // After SwiftUI has had a runloop tick to vend the window,
        // bring it forward and capture a reference for the close-watcher.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            if let window = NSApp.windows.first(where: { Self.isDashboard($0) }) {
                self.dashboardWindow = window
                window.collectionBehavior.insert(.fullScreenPrimary)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let window = NSApp.windows.first(where: { Self.isDashboard($0) }) {
            promoteToRegular()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menu bar app stays alive even when all windows close.
        false
    }

    // MARK: - Activation policy helpers

    private func promoteToRegular() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    private func demoteToAccessory() {
        // A small delay avoids a brief Dock-icon flicker.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // Only demote if no other dashboard windows are still up.
            let stillOpen = NSApp.windows.contains(where: {
                AppDelegate.isDashboard($0) && $0.isVisible
            })
            if !stillOpen {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    private static func isDashboard(_ window: NSWindow) -> Bool {
        // Filter out menu-bar host windows, panels, and SwiftUI internals.
        let cls = String(describing: type(of: window))
        if cls.contains("StatusBar") || cls.contains("Popover") { return false }
        return window.contentViewController != nil
            || window.styleMask.contains(.titled)
            || window.identifier?.rawValue == Self.dashboardWindowID
    }
}
