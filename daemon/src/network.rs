//! TCP network layer.
//!
//! The host accepts arbitrarily many concurrent peers (in v0.3 it accepted
//! exactly one and exited the accept loop afterwards — a hard correctness
//! bug). Outbound events from the local file watcher are fanned out via
//! `tokio::sync::broadcast`. Each peer task subscribes to the broadcast and
//! also re-broadcasts events received from its peer so other peers stay in
//! sync. Echoes are filtered by tagging every broadcast with the originating
//! peer's `SourceId`.
//!
//! Joiner mode reuses the same `handle_peer` plumbing — it just opens a
//! single outbound connection instead of accepting.

use crate::crypto::{EncryptedStream, Passphrase};
use crate::path_safe::safe_join;
use crate::proto::{self, FileBody, FileEvent, MAX_FRAME_BYTES};
use dashmap::DashMap;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{broadcast, mpsc};

/// Identifies the producer of an event so the broadcast hub can avoid
/// echoing events back to their originator. `0` is reserved for the local
/// file watcher; peers get monotonically increasing IDs from the counter.
type SourceId = u64;
const LOCAL_SOURCE_ID: SourceId = 0;
static NEXT_PEER_ID: AtomicU64 = AtomicU64::new(1);

/// What rides on the broadcast channel.
type LiveEvent = (SourceId, Arc<FileEvent>);

/// Shared per-instance state between the watcher, the broadcast hub, and
/// every peer task.
pub struct PeerHub {
    pub root: PathBuf,
    /// `path → fnv64(content)` — used to drop FSEvents echoes of writes that
    /// originated from a peer (we wrote the file, FSEvents fired, we'd send
    /// the same change back). Shared with the watcher in main.rs.
    pub file_hashes: Arc<DashMap<String, u64>>,
    /// `path → utf8 content` — last-known text content for files we've seen,
    /// used to compute diffy patches.
    pub file_state: Arc<DashMap<String, String>>,
    pub outbound: broadcast::Sender<LiveEvent>,
}

impl PeerHub {
    pub fn new(
        root: PathBuf,
        file_hashes: Arc<DashMap<String, u64>>,
        file_state: Arc<DashMap<String, String>>,
    ) -> Arc<Self> {
        let (outbound, _rx) = broadcast::channel::<LiveEvent>(1024);
        Arc::new(Self {
            root,
            file_hashes,
            file_state,
            outbound,
        })
    }
}

/// Bridge an mpsc stream of watcher-originated events into the broadcast
/// hub. Spawn this once per process.
pub fn spawn_watcher_bridge(hub: Arc<PeerHub>, mut watcher_rx: mpsc::Receiver<FileEvent>) {
    tokio::spawn(async move {
        while let Some(evt) = watcher_rx.recv().await {
            let _ = hub.outbound.send((LOCAL_SOURCE_ID, Arc::new(evt)));
        }
    });
}

/// Host: bind, accept forever, spawn a peer task per connection.
pub async fn start_host(port: u16, hub: Arc<PeerHub>, passphrase: Passphrase) {
    let bind_addr = format!("0.0.0.0:{port}");
    let listener = match TcpListener::bind(&bind_addr).await {
        Ok(l) => l,
        Err(e) => {
            eprintln!("❌ Failed to bind {bind_addr}: {e}");
            return;
        }
    };
    println!("📡 Host listening on {bind_addr}");
    println!("🔑 Passphrase: {}", passphrase.display());
    println!("   (share this with the joining peer)");

    loop {
        match listener.accept().await {
            Ok((sock, addr)) => {
                let _ = sock.set_nodelay(true);
                let hub = hub.clone();
                let pw = passphrase.clone();
                tokio::spawn(async move {
                    handle_peer(sock, addr, hub, pw, true).await;
                });
            }
            Err(e) => {
                eprintln!("⚠️  accept() error: {e}; retrying in 1s");
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        }
    }
}

/// Joiner: connect once. (Auto-reconnect lives in v0.5; for v0.4 a single
/// connect attempt with a clear error message is enough.)
pub async fn start_client(ip: &str, port: u16, hub: Arc<PeerHub>, passphrase: Passphrase) {
    let addr = format!("{ip}:{port}");
    println!("📡 Joining {addr}…");
    match TcpStream::connect(&addr).await {
        Ok(sock) => {
            let _ = sock.set_nodelay(true);
            let peer_addr = sock.peer_addr().ok();
            handle_peer(sock, peer_addr.unwrap_or_else(|| ([0, 0, 0, 0], 0).into()), hub, passphrase, false).await;
        }
        Err(e) => {
            eprintln!("❌ Failed to connect to {addr}: {e}");
        }
    }
}

/// Per-connection state machine. Runs the Noise handshake, performs the
/// initial-state catch-up if we're the host, then loops over the broadcast
/// hub (outbound) and the encrypted stream (inbound).
async fn handle_peer(
    sock: TcpStream,
    addr: SocketAddr,
    hub: Arc<PeerHub>,
    passphrase: Passphrase,
    is_host: bool,
) {
    let role = if is_host { "host" } else { "client" };
    println!("🤝 {role}: handshaking with {addr}…");

    let stream_result = if is_host {
        EncryptedStream::handshake_responder(sock, &passphrase).await
    } else {
        EncryptedStream::handshake_initiator(sock, &passphrase).await
    };

    let mut stream = match stream_result {
        Ok(s) => s,
        Err(e) => {
            eprintln!("🚨 Handshake with {addr} failed: {e} (wrong passphrase?)");
            return;
        }
    };
    println!("✅ Encrypted channel up with {addr}");

    let my_id: SourceId = NEXT_PEER_ID.fetch_add(1, Ordering::Relaxed);
    let mut sub = hub.outbound.subscribe();

    // Initial sync — host pushes every existing non-ignored file to the
    // brand-new client. Without this, joiners only ever see live changes.
    if is_host {
        if let Err(e) = send_initial_sync(&mut stream, &hub).await {
            eprintln!("⚠️  Initial sync to {addr} failed: {e}");
            return;
        }
    }

    loop {
        tokio::select! {
            // Inbound from peer.
            biased;
            recv = stream.recv() => {
                let bytes = match recv {
                    Ok(b) => b,
                    Err(e) => {
                        println!("🔌 {addr} disconnected: {e}");
                        return;
                    }
                };
                let event = match proto::decode(&bytes) {
                    Ok(e) => e,
                    Err(e) => {
                        eprintln!("🚨 {addr} sent malformed event: {e}; closing");
                        return;
                    }
                };
                if let Err(e) = apply_event(&hub, &event).await {
                    eprintln!("⚠️  apply_event failed: {e}");
                    continue;
                }
                // Re-broadcast so other connected peers stay consistent.
                let _ = hub.outbound.send((my_id, Arc::new(event)));
            }

            // Outbound from local watcher or another peer.
            live = sub.recv() => {
                match live {
                    Ok((origin, evt)) => {
                        if origin == my_id {
                            // Don't echo events back to their source.
                            continue;
                        }
                        let bytes = match proto::encode(&evt) {
                            Ok(b) => b,
                            Err(e) => {
                                eprintln!("⚠️  encode failed: {e}");
                                continue;
                            }
                        };
                        if bytes.len() > MAX_FRAME_BYTES {
                            eprintln!("⚠️  Skipping oversized event ({} bytes) for {}",
                                bytes.len(), evt.primary_path());
                            continue;
                        }
                        if let Err(e) = stream.send(&bytes).await {
                            eprintln!("🔌 send to {addr} failed: {e}");
                            return;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        eprintln!("⚠️  {addr} lagged {n} events behind; dropping connection");
                        return;
                    }
                    Err(broadcast::error::RecvError::Closed) => return,
                }
            }
        }
    }
}

/// Walk the watch root and stream every non-ignored, reasonably-sized file
/// to the freshly-connected peer as `Upsert(Full)` events. Uses the same
/// gitignore handling as the live watcher (kept in sync via .gitignore at
/// the watch root).
async fn send_initial_sync(
    stream: &mut EncryptedStream,
    hub: &PeerHub,
) -> std::io::Result<()> {
    use ignore::WalkBuilder;

    println!("📦 Initial sync starting…");
    let mut count = 0usize;
    let mut bytes = 0u64;

    let walker = WalkBuilder::new(&hub.root)
        .standard_filters(true)
        .hidden(false)
        .git_ignore(true)
        .git_global(false)
        .git_exclude(false)
        .build();

    for entry in walker.flatten() {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let metadata = match path.metadata() {
            Ok(m) => m,
            Err(_) => continue,
        };
        if metadata.len() > 50_000_000 {
            continue;
        }
        let rel = match path.strip_prefix(&hub.root) {
            Ok(r) => r.to_string_lossy().into_owned(),
            Err(_) => continue,
        };
        if rel.is_empty() {
            continue;
        }
        let content = match tokio::fs::read(path).await {
            Ok(c) => c,
            Err(_) => continue,
        };
        // Update local caches so live FSEvents echoes get suppressed.
        let mut hasher = DefaultHasher::new();
        content.hash(&mut hasher);
        hub.file_hashes
            .insert(path.to_string_lossy().into_owned(), hasher.finish());
        if let Ok(text) = std::str::from_utf8(&content) {
            hub.file_state
                .insert(path.to_string_lossy().into_owned(), text.to_string());
        }

        bytes += content.len() as u64;
        count += 1;
        let event = FileEvent::Upsert {
            path: rel,
            body: FileBody::Full(content),
        };
        let encoded = proto::encode(&event)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e.to_string()))?;
        stream.send(&encoded).await?;
    }

    println!("📦 Initial sync done: {count} files, {bytes} bytes");
    Ok(())
}

/// Apply a peer-originated event to the local file system, with full path
/// safety + caching. Errors are returned but not fatal to the peer task.
pub async fn apply_event(hub: &PeerHub, event: &FileEvent) -> std::io::Result<()> {
    match event {
        FileEvent::Upsert { path, body } => {
            let abs = match safe_join(&hub.root, path) {
                Ok(p) => p,
                Err(e) => {
                    eprintln!("🚨 Refusing peer-supplied path '{path}': {e}");
                    return Ok(());
                }
            };
            let abs_str = abs.to_string_lossy().into_owned();

            let final_content: Vec<u8> = match body {
                FileBody::Full(bytes) => {
                    println!("🌐 Upsert (full): {path} ({} bytes)", bytes.len());
                    bytes.clone()
                }
                FileBody::Patch(diff) => {
                    println!("🧩 Upsert (patch): {path}");
                    let local_text = tokio::fs::read_to_string(&abs).await.unwrap_or_default();
                    let patch = match diffy::Patch::from_str(diff) {
                        Ok(p) => p,
                        Err(e) => {
                            eprintln!("⚠️  Bad patch for {path}: {e}; skipping");
                            return Ok(());
                        }
                    };
                    match diffy::apply(&local_text, &patch) {
                        Ok(new) => new.into_bytes(),
                        Err(e) => {
                            eprintln!("⚠️  Patch apply failed for {path}: {e}");
                            return Ok(());
                        }
                    }
                }
            };

            let mut hasher = DefaultHasher::new();
            final_content.hash(&mut hasher);
            hub.file_hashes.insert(abs_str.clone(), hasher.finish());
            if let Ok(text) = std::str::from_utf8(&final_content) {
                hub.file_state.insert(abs_str, text.to_string());
            } else {
                hub.file_state.remove(&abs_str);
            }

            if let Some(parent) = abs.parent() {
                tokio::fs::create_dir_all(parent).await?;
            }
            tokio::fs::write(&abs, &final_content).await?;
        }

        FileEvent::Delete { path } => {
            let abs = match safe_join(&hub.root, path) {
                Ok(p) => p,
                Err(e) => {
                    eprintln!("🚨 Refusing delete path '{path}': {e}");
                    return Ok(());
                }
            };
            println!("🗑  Delete: {path}");
            let abs_str = abs.to_string_lossy().into_owned();
            hub.file_hashes.remove(&abs_str);
            hub.file_state.remove(&abs_str);
            // Best-effort: ignore "not found" on remote-driven deletes.
            match tokio::fs::remove_file(&abs).await {
                Ok(()) => {}
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(e),
            }
        }

        FileEvent::Rename { from, to } => {
            let from_abs = match safe_join(&hub.root, from) {
                Ok(p) => p,
                Err(e) => {
                    eprintln!("🚨 Refusing rename source '{from}': {e}");
                    return Ok(());
                }
            };
            let to_abs = match safe_join(&hub.root, to) {
                Ok(p) => p,
                Err(e) => {
                    eprintln!("🚨 Refusing rename target '{to}': {e}");
                    return Ok(());
                }
            };
            println!("🔀 Rename: {from} → {to}");
            if let Some(parent) = to_abs.parent() {
                tokio::fs::create_dir_all(parent).await?;
            }
            // Best-effort: ignore missing source (e.g., already renamed locally).
            match tokio::fs::rename(&from_abs, &to_abs).await {
                Ok(()) => {}
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(e),
            }
            let from_str = from_abs.to_string_lossy().into_owned();
            let to_str = to_abs.to_string_lossy().into_owned();
            if let Some((_, h)) = hub.file_hashes.remove(&from_str) {
                hub.file_hashes.insert(to_str.clone(), h);
            }
            if let Some((_, s)) = hub.file_state.remove(&from_str) {
                hub.file_state.insert(to_str, s);
            }
        }
    }
    Ok(())
}
