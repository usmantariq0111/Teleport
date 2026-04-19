# Teleport: P2P Zero-Config Code Sync for macOS

## The Problem
Git is designed for version control, not real-time collaboration. When two developers are pair-programming or hacking on the same feature, constantly pushing and pulling branches to share 2-line code changes completely destroys momentum. 

While tools like VS Code Live Share exist, they force a "Host/Guest" model. The guest developer is merely remote-controlling the host's IDE. They do not have the files locally, meaning they cannot use their preferred IDE (e.g., Xcode vs. VS Code), run their own local test servers, or execute their own terminal commands.

## The Solution: "Teleport"
Teleport is a premium, native macOS menu bar application that provides zero-config, lightning-fast, peer-to-peer directory syncing designed specifically for codebases.

It allows two developers to keep their project folders perfectly in sync in milliseconds, while allowing both to use their own local environments, IDEs, and tools.

### Core User Experience
1. **Zero Config:** Both developers install the lightweight Mac app.
2. **Instant Pairing:** Dev A drags their project folder onto the Menu Bar icon, generating a 4-digit secure code (or utilizing Apple AirDrop/Bonjour for 1-click pairing if in the same room).
3. **Real-time Sync:** Dev B enters the code. From that moment, any time either developer saves a file, the change is reflected on the other machine in under 50 milliseconds.

### Developer-Focused Features
* **Smart Ignored Files:** Unlike Dropbox or general-sync tools, Teleport knows it's dealing with code. It automatically ignores heavy, machine-specific directories like `node_modules`, `build`, `dist`, `.next`, and `.git`.
* **Bring Your Own IDE:** Because the files are physically synced to both local drives, Dev A can write in Neovim while Dev B writes in VS Code. Both can run `npm run dev` and have their own local `localhost:3000` running independently.

---

## Technical Architecture & Implementation

To achieve a premium, magical feel on macOS, the app requires a blend of native UI and high-performance systems programming.

### 1. The UI Layer (Swift & SwiftUI)
The user interface (menu bar dropdown, pairing popups, settings, and conflict resolution windows) must be built using native Swift and SwiftUI. This ensures the app feels lightweight, respects macOS design paradigms, and uses minimal memory when idling.

### 2. The File Watcher (macOS FSEvents)
Polling the file system for changes drains battery and introduces lag. Teleport uses the native macOS `FSEvents` (File System Events) API. The app registers with the macOS kernel, which instantly notifies the app the microsecond a file is modified, enabling near-instantaneous sync triggers.

### 3. The Networking Layer (P2P via WebRTC / MultipeerConnectivity)
Syncing code through a centralized cloud server introduces latency and privacy concerns.
* **Local Network (LAN/WiFi):** If developers are in the same office, the app utilizes Apple's `MultipeerConnectivity` framework for direct Mac-to-Mac communication via WiFi or Bluetooth, resulting in zero-latency transfers.
* **Remote (Internet):** For remote teams, the app establishes a secure, encrypted peer-to-peer tunnel using **WebRTC Data Channels**, allowing direct transfer between the two Macs without a middleman server storing the code.

### 4. Conflict Resolution Engine (CRDTs)
The most challenging edge case occurs when both developers edit the exact same file (e.g., `App.js`, line 10) simultaneously. 
* **Under the hood:** Teleport integrates a CRDT (Conflict-free Replicated Data Type) engine (such as Automerge). This is the same underlying mathematics that powers real-time collaboration in Figma and Google Docs, allowing it to mathematically merge parallel edits without data loss.
* **UI Fallback:** If a mathematical merge is impossible, Teleport intercepts the file save and instantly presents a native, sleek visual diff popup, allowing the developers to manually choose which code block to keep.

### 5. The Core Engine (Rust)
To handle the heavy lifting of WebRTC connections, CRDT mathematics, and fast diffing, the core "sync engine" can be written in Rust. Rust offers blistering speed and memory safety. The native Swift UI layer acts as a wrapper, sending commands to the Rust engine running in the background.
