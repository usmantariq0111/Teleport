# ⚡️ Teleport

![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
![Platform](https://img.shields.io/badge/Platform-macOS-lightgrey)
![Language](https://img.shields.io/badge/Language-Rust%20%7C%20Swift-orange)

**Teleport** is a high-performance, native macOS application designed for zero-latency, peer-to-peer directory synchronization between developers. 

It bypasses the limitations of traditional "Host/Guest" IDE extensions (like VS Code Live Share) by hooking directly into the OS-level file system. This allows developers to pair-program on the same codebase while using their own personal IDEs, terminal aliases, and environments.

---

## ✨ Features

- **Blazing Fast File Watching:** Powered by Rust's `notify` crate and macOS `FSEvents` for microsecond detection with zero battery drain.
- **P2P Tunnel:** Asynchronous TCP tunnel streams file diffs directly over the local network. No centralized cloud servers.
- **End-to-End Encryption:** Secures your code over the wire using the Noise Protocol (`snow`) and `ChaChaPoly_BLAKE2s`.
- **Bonjour Discovery:** Automatically discovers peers on your local network using mDNS/DNS-SD. No more typing IP addresses!
- **Smart Filtering:** Parses your `.gitignore` files to instantly drop noisy events (like heavy `node_modules` saves).
- **Native macOS UI:** A sleek, premium Menu Bar application built in SwiftUI.

---

## 🏗️ Architecture

Teleport is built using a hybrid architecture designed for maximum performance and native macOS integration:

1. **The Core Engine (Rust):** A headless background daemon. It hooks directly into the macOS `FSEvents` API.
2. **The P2P Tunnel (Rust):** The daemon uses an asynchronous TCP tunnel to stream file diffs directly to the connected peer.
3. **Smart Filtering (Rust):** Integrated with the industry-standard `ignore` crate.
4. **The Native Control Center (SwiftUI):** A beautiful native dropdown UI that manages the Rust daemon, handles persistent folder bookmarks, and pipes real-time logs.

---

## 📥 Download & Install

The easiest way to use Teleport is to grab the latest pre-built `.dmg` from the [Releases page](../../releases/latest):

1. Download **`Teleport-<version>.dmg`**.
2. Open the DMG and drag **Teleport.app** into the **Applications** folder.
3. Launch it from Spotlight or Launchpad.
4. The first time you run it macOS will say *"Teleport can't be opened because Apple cannot check it for malicious software"* — that's expected because the app is unsigned. Either:
   - **Right-click** Teleport.app in Finder → **Open** → **Open** in the dialog (this only needs to happen once), **or**
   - run this in Terminal:
     ```bash
     xattr -dr com.apple.quarantine /Applications/Teleport.app
     open /Applications/Teleport.app
     ```
5. Look for the ⚡ lightning-bolt icon in your menu bar (top-right). Click it → **Open Dashboard**.

> **Requirements:** macOS 14 Sonoma or newer (Apple Silicon or Intel).

---

## 🤝 Contributing

We welcome contributions! Please see our [Contributing Guide](CONTRIBUTING.md) for details on how to get started, set up your local development environment, and submit pull requests.

Please note that this project is released with a [Contributor Code of Conduct](CODE_OF_CONDUCT.md). By participating in this project you agree to abide by its terms.

If you discover a security vulnerability, please follow our [Security Policy](SECURITY.md).

---

## 🚀 How to Build & Run Locally

### Prerequisites
- macOS 14 (Sonoma) or newer
- Rust Toolchain (`cargo`)
- Swift Package Manager (`swift build`)

### 1. Build & launch the app (recommended)
This compiles the Rust daemon, the SwiftUI front-end, generates the app icon, and produces a self-contained `Teleport.app` bundle in `ui/`:

```bash
make run            # debug build + open Teleport.app
make app-release    # signed-ad-hoc release build
```

*Look for the lightning bolt icon in your Mac's Menu Bar at the top right of your screen — click it to open the dashboard.*

### 2. Build a distributable DMG
```bash
make dmg-release    # produces dist/Teleport-<version>.dmg
```

### 3. Or run unbundled (dev loop)
```bash
make run-ui         # cd ui && swift run
```

### 4. Testing the P2P Sync (Terminal Fallback)
If you want to run the daemon manually without the Swift UI, you can use the CLI commands. Both subcommands accept `--folder <path>` (defaults to the current directory) and `--port <port>` (defaults to `8080`).

**Terminal A (The Host):**
```bash
cd daemon
cargo run -- --folder ~/code/my-project host
```

**Terminal B (The Client):**
```bash
cd daemon
cargo run -- --folder ~/code/my-project-mirror join 127.0.0.1
```

---

## 📦 Cutting a release (maintainers)

Releases are fully automated by GitHub Actions. To publish a new version:

```bash
git tag v0.5.0
git push origin v0.5.0
```

The [`Release` workflow](.github/workflows/release.yml) will build the app, package it as a DMG, and create a GitHub Release.

---

## 🗺️ Roadmap to Production

- [x] Phase 1: OS-Level `FSEvents` File Watcher (Rust)
- [x] Phase 2: Direct Local P2P TCP Tunnel (Rust)
- [x] Phase 3: Native macOS Menu Bar Controller (SwiftUI)
- [x] Phase 4: Dynamic `.gitignore` Filtering (`ignore` crate)
- [x] Phase 5: Bonjour Network Discovery & Persistent Bookmarks
- [ ] Phase 6: Integrate `automerge-rs` CRDTs for mathematical conflict resolution
- [ ] Phase 7: Upgrade TCP to `webrtc-rs` for NAT traversal and remote internet syncing
- [x] Phase 8: GitHub Actions CI/CD for pre-compiled `.dmg` distribution
- [ ] Phase 9: Code-signing + Apple notarization for one-click installs (no Gatekeeper warning)

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

*Built for developers who demand native performance.*
