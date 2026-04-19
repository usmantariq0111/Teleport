use dashmap::DashMap;
use serde::{Deserialize, Serialize};
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;

const MAX_PAYLOAD_SIZE: usize = 50_000_000; // 50 MB

#[derive(Serialize, Deserialize, Debug)]
pub struct SyncMessage {
    pub path: String,
    pub is_patch: bool,
    pub content: Vec<u8>,
}

pub async fn start_host(rx: mpsc::Receiver<SyncMessage>, file_hashes: Arc<DashMap<String, u64>>, file_state: Arc<DashMap<String, String>>) {
    println!("📡 Host mode: Listening on 0.0.0.0:8080...");
    let listener = TcpListener::bind("0.0.0.0:8080").await.unwrap();

    if let Ok((socket, addr)) = listener.accept().await {
        println!("✅ Client connected from: {:?}", addr);
        handle_connection(socket, rx, file_hashes, file_state).await;
    }
}

pub async fn start_client(ip: &str, rx: mpsc::Receiver<SyncMessage>, file_hashes: Arc<DashMap<String, u64>>, file_state: Arc<DashMap<String, String>>) {
    let addr = format!("{}:8080", ip);
    println!("📡 Join mode: Connecting to {}...", addr);

    match TcpStream::connect(&addr).await {
        Ok(socket) => {
            println!("✅ Successfully connected to host!");
            handle_connection(socket, rx, file_hashes, file_state).await;
        }
        Err(e) => {
            eprintln!("❌ Failed to connect: {}", e);
        }
    }
}

async fn handle_connection(socket: TcpStream, mut rx: mpsc::Receiver<SyncMessage>, file_hashes: Arc<DashMap<String, u64>>, file_state: Arc<DashMap<String, String>>) {
    let (mut read_half, mut write_half) = socket.into_split();

    let read_task = tokio::spawn(async move {
        let mut length_buf = [0u8; 4];
        let root_path = std::env::current_dir().unwrap();
        
        loop {
            match read_half.read_exact(&mut length_buf).await {
                Ok(_) => {
                    let msg_len = u32::from_be_bytes(length_buf) as usize;
                    
                    if msg_len > MAX_PAYLOAD_SIZE {
                        eprintln!("🚨 SECURITY ALERT: Peer attempted to send a payload of {} bytes (> 50MB limit). Disconnecting.", msg_len);
                        break;
                    }
                    
                    let mut msg_buf = vec![0u8; msg_len];

                    if let Err(e) = read_half.read_exact(&mut msg_buf).await {
                        eprintln!("❌ Failed to read payload: {}", e);
                        break;
                    }

                    if let Ok(msg) = serde_json::from_slice::<SyncMessage>(&msg_buf) {
                        
                        if msg.path.contains("..") || msg.path.starts_with('/') || msg.path.starts_with('\\') {
                            eprintln!("🚨 SECURITY ALERT: Peer attempted Path Traversal with path '{}'. Dropping payload.", msg.path);
                            continue;
                        }
                        
                        let abs_path = root_path.join(&msg.path);
                        let abs_path_str = abs_path.to_string_lossy().into_owned();
                        
                        let final_content: Vec<u8>;
                        
                        if msg.is_patch {
                            println!("🧩 Received patch for: {}", msg.path);
                            let patch_str = String::from_utf8_lossy(&msg.content);
                            let local_content = tokio::fs::read_to_string(&abs_path).await.unwrap_or_default();
                            
                            if let Ok(patch) = diffy::Patch::from_str(&patch_str) {
                                if let Ok(new_content) = diffy::apply(&local_content, &patch) {
                                    final_content = new_content.into_bytes();
                                } else {
                                    eprintln!("❌ Failed to apply patch for: {}", msg.path);
                                    continue;
                                }
                            } else {
                                eprintln!("❌ Failed to parse patch for: {}", msg.path);
                                continue;
                            }
                        } else {
                            println!("🌐 Received full file: {}", msg.path);
                            final_content = msg.content;
                        }
                        
                        // Compute hash of the FINAL applied content
                        let mut hasher = DefaultHasher::new();
                        final_content.hash(&mut hasher);
                        let hash = hasher.finish();
                        
                        // Update Caches so FSEvents ignores the write AND can diff properly later
                        file_hashes.insert(abs_path_str.clone(), hash);
                        if let Ok(text) = String::from_utf8(final_content.clone()) {
                            file_state.insert(abs_path_str, text);
                        }

                        // Write to local disk natively
                        if let Some(parent) = abs_path.parent() {
                            let _ = tokio::fs::create_dir_all(parent).await;
                        }
                        if let Err(e) = tokio::fs::write(&abs_path, final_content).await {
                            eprintln!("❌ Failed to write to disk: {}", e);
                        }
                    }
                }
                Err(_) => {
                    println!("❌ Peer disconnected.");
                    break;
                }
            }
        }
    });

    let write_task = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            if let Ok(json_bytes) = serde_json::to_vec(&msg) {
                let len = json_bytes.len() as u32;
                if write_half.write_all(&len.to_be_bytes()).await.is_err() {
                    break;
                }
                if write_half.write_all(&json_bytes).await.is_err() {
                    break;
                }
            }
        }
    });

    let _ = tokio::join!(read_task, write_task);
}
