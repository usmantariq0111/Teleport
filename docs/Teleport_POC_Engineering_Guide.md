# Teleport: Engineering POC & Architecture Guide

*From the desk of a Senior Systems Engineer*

## 1. The Form Factor: What exactly is this?

**It is NOT an IDE Extension.** 
If you build a VS Code extension, you instantly alienate developers who use WebStorm, IntelliJ, Xcode, Neovim, or Cursor. 

**It IS a native macOS Menu Bar Application running a background Daemon.**
To build something truly unique that gives developers ultimate freedom, the app must sit at the *Operating System level*, not the editor level. 
* **The UI:** A beautiful, lightweight SwiftUI Menu Bar drop-down.
* **The Engine:** A headless background process (daemon) that hooks directly into the macOS kernel file system.

Because it sits at the OS level, Developer A can use Neovim, Developer B can use VS Code, and both can run their own local terminal scripts. The app doesn't care about the editor; it only cares about the file system.

---

## 2. The Senior Engineer's Vision: How to make it truly unique

To build something that developers will pay for, we can't just build a wrapper around `rsync`. We need to build a modern, conflict-free, zero-latency pipeline.

Here is the "Secret Sauce" stack:
1. **File Watching:** Apple's `FSEvents` (C API wrapped in Swift/Rust). Do not poll the disk. Polling burns battery and is slow. Hook into the kernel so the OS *pushes* changes to your app in microseconds.
2. **The Sync Engine:** Rust. Write the core logic in Rust. It's memory-safe, blazing fast, and handles concurrent network connections better than almost anything else.
3. **The Network:** WebRTC Data Channels. Do not use a centralized cloud server (like AWS or Firebase) to route code. It's slow and poses security risks for enterprise code. WebRTC creates a direct, encrypted Peer-to-Peer tunnel between Mac A and Mac B.
4. **The Conflict Resolver:** CRDTs (Conflict-free Replicated Data Types). If two devs edit the exact same line, you cannot just overwrite. Integrate a library like `Automerge` or `Yjs` into the Rust core. This allows the files to merge mathematically, just like Google Docs, but on local files.

---

## 3. The POC (Proof of Concept) Roadmap

Do not start by designing a UI. As an engineer, you must prove the riskiest technical assumptions first. 

### Step 1: The Headless Watcher (Days 1-2)
**Goal:** Prove you can detect a file save instantly.
* **Action:** Build a simple Command Line Interface (CLI) tool in Rust (using the `notify` crate) or Swift (using `EonilFSEvents`).
* **Test:** Run the CLI `teleport watch ./my-project`. Open a file in that folder, hit save. Your CLI should print out: `Detected modification: src/App.js` in less than 5 milliseconds.

### Step 2: The P2P Tunnel (Days 3-5)
**Goal:** Prove you can send data directly between two computers without a central server.
* **Action:** Implement WebRTC. (Since WebRTC requires a "signaling" phase to exchange IP addresses, you can use a tiny free socket.io server just for the initial handshake).
* **Test:** Run `teleport host` on Mac A. It generates a 4-digit code. Run `teleport join 1234` on Mac B. The two CLIs connect directly. Type "Hello" in Mac A, and it appears in Mac B.

### Step 3: The "Dumb" Sync (Days 6-8)
**Goal:** Connect Step 1 and Step 2.
* **Action:** When the Watcher (Step 1) detects a file save, read the file, and send its contents over the WebRTC tunnel (Step 2). The receiving Mac writes the file to disk.
* **Test:** Dev A saves `index.js`. Dev B sees `index.js` update on their screen instantly. 

### Step 4: The UI Wrapper (Days 9-10)
**Goal:** Make it a macOS product.
* **Action:** Open Xcode. Create a new SwiftUI app. Check the "Menu Bar Extra" box so it doesn't have a main window. 
* **Action:** Have the Swift UI app spawn your Rust/CLI binary in the background as a subprocess. The UI is just a beautiful "remote control" for the background engine. It displays the connection status and handles the "Drag and Drop folder" interactions.

### Step 5: Smart Ignores & Diffing (V2 - Post-POC)
* Implement `.gitignore` parsing so the engine never tries to sync `node_modules` or `.git` folders.
* Instead of sending the whole file on every save, implement Meyers Diff algorithm to send only the exact characters that changed (e.g., "Insert 'x' at line 10").

---

### Summary for the Dev
By building it this way (OS-level daemon + P2P networking), you solve the biggest complaint developers have with Live Share: "I don't want to use your environment, I want to use MINE." This architecture allows everyone to use their own tools while collaborating perfectly.
