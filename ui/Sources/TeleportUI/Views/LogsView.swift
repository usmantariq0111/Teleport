import SwiftUI

struct LogsView: View {
    @EnvironmentObject var daemon: DaemonController
    @State private var search: String = ""
    @State private var autoScroll: Bool = true
    @State private var levelFilter: LogEntry.Level? = nil

    var filtered: [LogEntry] {
        daemon.logs.filter { entry in
            if let levelFilter, entry.level != levelFilter { return false }
            guard !search.isEmpty else { return true }
            return entry.line.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            terminal
        }
        .background(Theme.Palette.logBg)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.gray)
            TextField("Search logs", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white)

            Menu {
                Button("All") { levelFilter = nil }
                Divider()
                Button("Patches")    { levelFilter = .patch }
                Button("Full Files") { levelFilter = .fullFile }
                Button("Success")    { levelFilter = .success }
                Button("Warnings")   { levelFilter = .warn }
                Button("Errors")     { levelFilter = .error }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text(levelLabel)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(.white.opacity(0.85))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Toggle(isOn: $autoScroll) {
                Text("Auto-scroll")
                    .font(.system(size: 11, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Theme.Palette.accent)
            .foregroundStyle(.white.opacity(0.85))

            Button {
                daemon.copyLogsToClipboard()
            } label: {
                Image(systemName: "doc.on.doc")
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("Copy all logs")

            Button {
                daemon.clearLogs()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("Clear logs")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.55))
    }

    private var levelLabel: String {
        switch levelFilter {
        case .none: return "ALL"
        case .info: return "INFO"
        case .success: return "OK"
        case .warn: return "WARN"
        case .error: return "ERROR"
        case .patch: return "PATCH"
        case .fullFile: return "FILE"
        }
    }

    // MARK: - Terminal

    private var terminal: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { entry in
                        logRow(entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: filtered.count) { _, _ in
                guard autoScroll, let last = filtered.last else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func logRow(_ entry: LogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(DaemonController.timeFormatter.string(from: entry.timestamp))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.gray)
                .frame(width: 70, alignment: .leading)
            Text(badge(for: entry.level))
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color(for: entry.level).opacity(0.85))
                )
                .frame(width: 50, alignment: .leading)
            Text(entry.line)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(color(for: entry.level))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func color(for level: LogEntry.Level) -> Color {
        switch level {
        case .info:     return .white.opacity(0.92)
        case .success:  return Theme.Palette.success
        case .warn:     return Theme.Palette.warning
        case .error:    return Theme.Palette.danger
        case .patch:    return .cyan
        case .fullFile: return Theme.Palette.accent
        }
    }

    private func badge(for level: LogEntry.Level) -> String {
        switch level {
        case .info:     return "INFO"
        case .success:  return " OK "
        case .warn:     return "WARN"
        case .error:    return "ERR "
        case .patch:    return "PTCH"
        case .fullFile: return "FILE"
        }
    }
}
