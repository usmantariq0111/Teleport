# Teleport

Zero-config, peer-to-peer directory syncing for developers.

## Architecture

* **Daemon (`/daemon`)**: A high-performance Rust engine that watches the file system via `FSEvents`, resolves conflicts via CRDTs, and manages P2P WebRTC tunnels.
* **UI (`/ui`)**: A lightweight SwiftUI macOS Menu Bar application that serves as the control center for the background daemon.

## Getting Started
(Documentation pending execution of POC Phase 1)
