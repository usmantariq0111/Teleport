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

    private let kFolderKey   = "teleport.watchFolder.path"
    private let kRecentKey   = "teleport.watchFolder.recent"
    private let kBookmarkKey = "teleport.watchFolder.bookmark"
    private let maxRecent = 5

    init() {
        // Prefer the bookmark — it survives the user moving/renaming the
        // folder. Fall back to the raw path for older installs that
        // never had a bookmark stored.
        if let bookmark = UserDefaults.standard.data(forKey: kBookmarkKey),
           let resolved = Self.resolveBookmark(bookmark) {
            folderURL = resolved
            // Path may have changed since the bookmark was written.
            UserDefaults.standard.set(resolved.path, forKey: kFolderKey)
        } else if let stored = UserDefaults.standard.string(forKey: kFolderKey) {
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

    /// Resolve a stored bookmark blob back to a URL, refreshing it
    /// transparently if the system reports `isStale`. Returns nil if the
    /// bookmark is invalid or the underlying folder is gone for good.
    private static func resolveBookmark(_ data: Data) -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if isStale,
           let refreshed = try? url.bookmarkData(
               options: [.withSecurityScope],
               includingResourceValuesForKeys: nil,
               relativeTo: nil
           ) {
            UserDefaults.standard.set(refreshed, forKey: "teleport.watchFolder.bookmark")
        }
        return url
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
    /// switching between recents). Stores both a path string (for legacy
    /// readers and for passing to the daemon CLI) and a security-scoped
    /// bookmark so we can find the folder again after a rename or move.
    func setFolder(_ url: URL) {
        folderURL = url
        UserDefaults.standard.set(url.path, forKey: kFolderKey)
        if let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(bookmark, forKey: kBookmarkKey)
        }
        addToRecents(url)
    }

    /// Clear the selected folder.
    func clearFolder() {
        folderURL = nil
        UserDefaults.standard.removeObject(forKey: kFolderKey)
        UserDefaults.standard.removeObject(forKey: kBookmarkKey)
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
