use dashmap::DashMap;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;

#[derive(Serialize, Deserialize, Debug)]
pub struct SyncMessage {
    pub path: String,
    pub content: Vec<u8>,
}

pub async fn start_host(rx: mpsc::Receiver<SyncMessage>, ignore_cache: Arc<DashMap<String, bool>>) {
    println!("📡 Host mode: Listening on 0.0.0.0:8080...");
    let listener = TcpListener::bind("0.0.0.0:8080").await.unwrap();

    if let Ok((socket, addr)) = listener.accept().await {
        println!("✅ Client connected from: {:?}", addr);
        handle_connection(socket, rx, ignore_cache).await;
    }
}

pub async fn start_client(ip: &str, rx: mpsc::Receiver<SyncMessage>, ignore_cache: Arc<DashMap<String, bool>>) {
    let addr = format!("{}:8080", ip);
    println!("📡 Join mode: Connecting to {}...", addr);

    match TcpStream::connect(&addr).await {
        Ok(socket) => {
            println!("✅ Successfully connected to host!");
            handle_connection(socket, rx, ignore_cache).await;
        }
        Err(e) => {
            eprintln!("❌ Failed to connect: {}", e);
        }
    }
}

async fn handle_connection(socket: TcpStream, mut rx: mpsc::Receiver<SyncMessage>, ignore_cache: Arc<DashMap<String, bool>>) {
    let (mut read_half, mut write_half) = socket.into_split();

    // Spawn a task to READ from the network and write to local disk
    let read_task = tokio::spawn(async move {
        let mut length_buf = [0u8; 4];
        let root_path = std::env::current_dir().unwrap();
        
        loop {
            // 1. Read the length prefix (4 bytes)
            match read_half.read_exact(&mut length_buf).await {
                Ok(_) => {
                    let msg_len = u32::from_be_bytes(length_buf) as usize;
                    let mut msg_buf = vec![0u8; msg_len];

                    // 2. Read the actual JSON payload
                    if let Err(e) = read_half.read_exact(&mut msg_buf).await {
                        eprintln!("❌ Failed to read payload: {}", e);
                        break;
                    }

                    // 3. Parse JSON
                    if let Ok(msg) = serde_json::from_slice::<SyncMessage>(&msg_buf) {
                        println!("🌐 Received remote file: {}", msg.path);
                        
                        let abs_path = root_path.join(&msg.path);
                        let abs_path_str = abs_path.to_string_lossy().into_owned();
                        
                        // 4. Add to Ignore Cache (absolute path) to prevent echo loop
                        ignore_cache.insert(abs_path_str, true);

                        // 5. Write to local disk natively
                        if let Some(parent) = abs_path.parent() {
                            let _ = tokio::fs::create_dir_all(parent).await;
                        }
                        if let Err(e) = tokio::fs::write(&abs_path, msg.content).await {
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

    // Spawn a task to READ from local FSEvents and write to the network
    let write_task = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            if let Ok(json_bytes) = serde_json::to_vec(&msg) {
                let len = json_bytes.len() as u32;
                // Send length prefix followed by payload securely
                if write_half.write_all(&len.to_be_bytes()).await.is_err() {
                    break;
                }
                if write_half.write_all(&json_bytes).await.is_err() {
                    break;
                }
            }
        }
    });

    // Keep the connection alive
    let _ = tokio::join!(read_task, write_task);
}
