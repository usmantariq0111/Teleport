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

## 📥 Download & Install (for users)

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

## 🚀 How to Build & Run Locally (for contributors)

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

The app launches as a true menu-bar utility (`LSUIElement`), so it does **not** show up in the Dock or App Switcher by default. When you open the dashboard from the menu, Teleport temporarily promotes itself to a regular app so the window can take focus, then quietly demotes back once you close the window — no leftover Dock icon.

### 2. Build a distributable DMG
```bash
make dmg-release    # produces dist/Teleport-<version>.dmg
```

### 3. Or run unbundled (dev loop)
```bash
make run-ui         # cd ui && swift run
```

### 4. Testing the P2P Sync (Terminal Fallback)
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

## 📦 Cutting a release (maintainers)

Releases are fully automated by GitHub Actions. To publish a new version:

```bash
# bump the version in ui/Resources/Info.plist if you want it baked in,
# then tag and push:
git tag v0.2.0
git push origin v0.2.0
```

The [`Release` workflow](.github/workflows/release.yml) will:
1. Spin up a `macos-14` runner with Xcode + Rust toolchains.
2. Stamp `Info.plist` with the tag version.
3. Build the Rust daemon + SwiftUI app in release mode.
4. Bundle everything into `Teleport.app` with the icon.
5. Package it as `Teleport-<version>.dmg` (drag-to-/Applications layout).
6. Compute the SHA-256 checksum.
7. Create a GitHub Release with the DMG and checksum attached and auto-generated release notes.

You can also trigger a release manually from the **Actions → Release → Run workflow** button.

The [`CI` workflow](.github/workflows/ci.yml) runs on every push and PR — it verifies that both targets build cleanly and uploads a downloadable `.app` artifact for reviewers.

---

## 🗺️ Roadmap to Production

- [x] Phase 1: OS-Level `FSEvents` File Watcher (Rust)
- [x] Phase 2: Direct Local P2P TCP Tunnel (Rust)
- [x] Phase 3: Native macOS Menu Bar Controller (SwiftUI)
- [x] Phase 4: Dynamic `.gitignore` Filtering (`ignore` crate)
- [ ] Phase 5: Integrate `automerge-rs` CRDTs for mathematical conflict resolution
- [ ] Phase 6: Upgrade TCP to `webrtc-rs` for NAT traversal and remote internet syncing
- [x] Phase 7: GitHub Actions CI/CD for pre-compiled `.dmg` distribution
- [ ] Phase 8: Code-signing + Apple notarization for one-click installs (no Gatekeeper warning)

---

*Built for developers who demand native performance.*
