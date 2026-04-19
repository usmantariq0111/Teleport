import SwiftUI
import AppKit

/// Manages the user-selected folder that the Rust daemon watches.
///
/// Persists the selection across launches via `UserDefaults` and tracks
/// up to 5 most-recently-used folders so the user can switch back quickly.
@MainActor
final class WatchFolderManager: ObservableObject {

    static let shared = WatchFolderManager()

    @Published private(set) var folderURL: URL?
    @Published private(set) var recentFolders: [URL] = []

    private let kFolderKey = "teleport.watchFolder.path"
    private let kRecentKey = "teleport.watchFolder.recent"
    private let maxRecent = 5

    init() {
        if let stored = UserDefaults.standard.string(forKey: kFolderKey) {
            let url = URL(fileURLWithPath: stored)
            if FileManager.default.fileExists(atPath: stored) {
                folderURL = url
            }
        }
        if let recent = UserDefaults.standard.array(forKey: kRecentKey) as? [String] {
            recentFolders = recent
                .filter { FileManager.default.fileExists(atPath: $0) }
                .map { URL(fileURLWithPath: $0) }
        }
    }

    /// Convenience: the folder's display name (last path component).
    var folderName: String {
        folderURL?.lastPathComponent ?? "No folder selected"
    }

    /// Path string suitable for the daemon `--folder` argument.
    var folderPath: String? {
        folderURL?.path
    }

    /// Display path that abbreviates `$HOME` to `~` for cleaner UI.
    var displayPath: String {
        guard let url = folderURL else { return "—" }
        let home = NSHomeDirectory()
        let path = url.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// Show the system folder picker. Calls the completion with the
    /// chosen folder, or `nil` if the user cancelled.
    func pickFolder(completion: ((URL?) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to sync"
        panel.message = "Teleport will watch this folder for changes and stream them to your peer."
        panel.prompt = "Select Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = folderURL ?? FileManager.default.homeDirectoryForCurrentUser

        // Bring the picker forward when invoked from the menu bar.
        NSApp.activate(ignoringOtherApps: true)

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                completion?(nil)
                return
            }
            Task { @MainActor [weak self] in
                self?.setFolder(url)
                completion?(url)
            }
        }
    }

    /// Programmatically set the folder (used both by the picker and for
    /// switching between recents).
    func setFolder(_ url: URL) {
        folderURL = url
        UserDefaults.standard.set(url.path, forKey: kFolderKey)
        addToRecents(url)
    }

    /// Clear the selected folder.
    func clearFolder() {
        folderURL = nil
        UserDefaults.standard.removeObject(forKey: kFolderKey)
    }

    func revealInFinder() {
        guard let url = folderURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func addToRecents(_ url: URL) {
        var list = recentFolders.filter { $0.path != url.path }
        list.insert(url, at: 0)
        if list.count > maxRecent {
            list = Array(list.prefix(maxRecent))
        }
        recentFolders = list
        UserDefaults.standard.set(list.map { $0.path }, forKey: kRecentKey)
    }
}
