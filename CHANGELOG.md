# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Bonjour Discovery**: The UI now automatically discovers peers on the local network using mDNS/DNS-SD.
- **Security-Scoped Bookmarks**: The UI persists folder access across restarts so you don't have to select the folder every time.
- **Real-time Uptime Tracking**: The dashboard now displays a live uptime counter.
- **Network Interfaces**: The dashboard displays all local network IPs to help you connect to peers.
- **Secure Passphrase Handling**: The daemon now receives the passphrase securely via the environment instead of CLI arguments, preventing exposure in `ps` or Activity Monitor.
- **Log Redaction**: The UI automatically redacts the passphrase from any logs displayed in the dashboard.

### Changed
- **Performance**: Replaced `DefaultHasher` with `xxhash-rust` (`xxh3_64`) for 10-15x faster file content fingerprinting.
- **Performance**: Optimized log persistence to use a single, long-lived `FileHandle`, drastically reducing syscall overhead.
- **Performance**: Implemented batched log processing with a debounce timer to prevent SwiftUI view thrashing.
- **Security**: The passphrase is wiped from memory upon drop using the `zeroize` crate.
- **Robustness**: The daemon now explicitly checks for UTF-8 validity before applying patches to prevent silent file corruption.

### Fixed
- **Memory Leak**: Fixed a retain cycle in the Bonjour browser's `NetServiceResolverDelegate`.
- **UI**: Clamped the network port input field to the valid range (1-65535).
- **App Lifecycle**: Fixed an issue where the app would bypass Apple's window block by avoiding `NSApp.setActivationPolicy(.regular)`.

## [0.4.0] - 2026-04-10
### Added
- Initial public proof-of-concept release.
- Rust daemon for high-performance file watching using `FSEvents`.
- P2P TCP tunnel for streaming file diffs.
- Noise Protocol (`snow`) for authenticated, encrypted transport.
- SwiftUI native macOS menu bar application.
- Dynamic `.gitignore` filtering.
- GitHub Actions CI/CD pipeline for pre-compiled `.dmg` distribution.
