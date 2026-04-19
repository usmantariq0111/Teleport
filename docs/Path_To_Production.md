# Teleport: Path to Production

This document outlines the engineering roadmap to take the Teleport Proof-of-Concept (POC) to a production-ready, open-source tool that anyone on GitHub can download and use.

## 1. Distribution & GitHub Usability (The "Open Source" factor)
To get users testing this immediately, they shouldn't have to compile Rust and Swift from scratch.
* **Pre-compiled Binaries (GitHub Actions):** We need to set up a CI/CD pipeline using GitHub Actions. Every time we push code, the pipeline should automatically compile the Rust daemon for macOS (`aarch64-apple-darwin` and `x86_64-apple-darwin`) and build the Swift app into a signed `.app` bundle.
* **Homebrew Tap:** Developers hate manual installations. We should create a custom Homebrew tap so anyone can install it via `brew install teleport-sync`.
* **The Release DMG:** We should package the UI and the Daemon into a single Apple Disk Image (`.dmg`). When the user drags `Teleport.app` to their Applications folder, the Rust binary is bundled *inside* it.

## 2. Core Engine Improvements (Rust)
The POC proves the concept, but production requires bulletproofing the edge cases:
* **Diffing & Patching:** Right now, we just trigger an event. In production, we must integrate an algorithm like `Myers Diff`. If a user changes 1 line in a 10,000 line file, we only send a 50-byte patch over the network, not a 5MB payload.
* **Conflict Resolution (CRDTs):** We must integrate the `automerge-rs` crate. If Dev A and Dev B type at the same time, the daemon must mathematically merge the text trees rather than blindly overwriting the file.
* **Bi-directional Sync:** The POC is one-way (Host -> Join). Production requires a full Peer-to-Peer protocol where both nodes are equal and can stream changes concurrently.

## 3. Networking Upgrades (WebRTC)
TCP works locally, but production requires remote work.
* **WebRTC Integration:** We replace `tokio::net::TcpStream` with the `webrtc-rs` crate. This allows NAT traversal (hole punching) so corporate firewalls don't block the connection.
* **Signaling Server:** We need a free, lightweight signaling server (e.g., hosted on Cloudflare Workers or a tiny Node.js app). The Menu Bar app generates a 6-digit code. The signaling server temporarily holds Dev A's IP address until Dev B enters the code, establishes the direct P2P WebRTC tunnel, and then the server drops out of the loop completely.

## 4. Native UI Polish (SwiftUI)
* **Onboarding Flow:** A beautiful, native macOS welcome screen explaining what the app does on first launch.
* **Settings Window:** Allow users to manually add custom ignore paths or configure specific network ports.
* **Launch on Login:** Integrate `SMAppService` so Teleport automatically starts quietly in the background when the Mac boots.
