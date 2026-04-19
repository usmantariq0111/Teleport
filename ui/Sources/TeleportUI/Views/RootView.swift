import SwiftUI

/// The dashboard window. A sidebar drives navigation between
/// the dashboard, live logs, and settings panes.
struct RootView: View {
    @State private var selection: DashboardTab = .dashboard

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(selection: $selection)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 920, minHeight: 580)
        .background(VisualEffectView(material: .windowBackground).ignoresSafeArea())
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .dashboard: DashboardView()
        case .logs:      LogsView()
        case .settings:  SettingsView()
        }
    }
}
