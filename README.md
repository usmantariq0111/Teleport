# ⚡️ Teleport

![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
![Platform](https://img.shields.io/badge/Platform-macOS-lightgrey)
![Language](https://img.shields.io/badge/Language-Rust%20%7C%20Swift-orange)

**Teleport** is a high-performance, native macOS application designed for zero-latency, peer-to-peer directory synchronization between developers. 

It bypasses the limitations of traditional "Host/Guest" IDE extensions (like VS Code Live Share) by hooking directly into the OS-level file system. This allows developers to pair-program on the same codebase while using their own personal IDEs, terminal aliases, and environments.

---

## 🏗️ Architecture

Teleport is built using a hybrid architecture designed for maximum performance and native macOS integration:

1. **The Core Engine (Rust):** A headless background daemon powered by `tokio` and the `notify` crate. It hooks directly into the macOS `FSEvents` API to detect file modifications in microseconds with zero battery drain.
2. **The P2P Tunnel (Rust):** The daemon uses an asynchronous TCP tunnel to stream file diffs directly to the connected peer over the local network (skipping centralized cloud servers entirely).
3. **Smart Filtering (Rust):** Integrated with the industry-standard `ignore` crate, the daemon dynamically parses your `.gitignore` files to instantly drop noisy events (like heavy `node_modules` saves).
4. **The Native Control Center (SwiftUI):** A sleek, premium macOS Menu Bar application that manages the Rust daemon. It spawns the background processes and pipes the real-time FSEvents logs directly into a beautiful native dropdown UI.

---

## 🚀 How to Run Locally

### Prerequisites
- macOS
- Rust Toolchain (`cargo`)
- Swift Package Manager (`swift build`)

### 1. Start the UI
The native macOS Menu Bar app acts as your remote control for the entire system.
```bash
cd ui
swift build
./.build/debug/TeleportUI
```
*Look for the lightning bolt icon in your Mac's Menu Bar at the top right of your screen!*

### 2. Testing the P2P Sync (Terminal Fallback)
If you want to run the daemon manually without the Swift UI, you can use the CLI commands:

**Terminal A (The Host):**
```bash
cd daemon
cargo run -- host
```

**Terminal B (The Client):**
```bash
cd daemon
cargo run -- join 127.0.0.1
```

Any file saved in the directory will be instantly caught by `FSEvents` and streamed to the connected peer!

---

## 🗺️ Roadmap to Production

- [x] Phase 1: OS-Level `FSEvents` File Watcher (Rust)
- [x] Phase 2: Direct Local P2P TCP Tunnel (Rust)
- [x] Phase 3: Native macOS Menu Bar Controller (SwiftUI)
- [x] Phase 4: Dynamic `.gitignore` Filtering (`ignore` crate)
- [ ] Phase 5: Integrate `automerge-rs` CRDTs for mathematical conflict resolution
- [ ] Phase 6: Upgrade TCP to `webrtc-rs` for NAT traversal and remote internet syncing
- [ ] Phase 7: GitHub Actions CI/CD for pre-compiled `.dmg` distribution

---

*Built for developers who demand native performance.*
