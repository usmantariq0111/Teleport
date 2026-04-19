mod network;

use clap::{Parser, Subcommand};
use dashmap::DashMap;
use ignore::gitignore::GitignoreBuilder;
use notify::{Config, Event, RecommendedWatcher, RecursiveMode, Watcher};
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::Path;
use std::sync::Arc;
use tokio::sync::mpsc;

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Act as the host (listens for connections)
    Host,
    /// Connect to an existing host
    Join {
        /// IP address of the host
        ip: String,
    },
}

#[tokio::main]
async fn main() -> notify::Result<()> {
    let cli = Cli::parse();

    println!("Teleport Daemon starting...");
    let path = std::env::current_dir().unwrap();

    let gitignore_path = path.join(".gitignore");
    let mut builder = GitignoreBuilder::new(&path);
    
    builder.add_line(None, ".git").unwrap();
    builder.add_line(None, "target").unwrap();
    builder.add_line(None, ".build").unwrap();
    
    if gitignore_path.exists() {
        if let Some(err) = builder.add(&gitignore_path) {
            eprintln!("Error parsing .gitignore: {}", err);
        } else {
            println!("✅ Loaded .gitignore rules dynamically");
        }
    }
    
    let gitignore = builder.build().unwrap().clone();

    let (tx, rx) = mpsc::channel::<network::SyncMessage>(100);

    let file_hashes = Arc::new(DashMap::<String, u64>::new());
    let watcher_hashes = file_hashes.clone();
    
    let file_state = Arc::new(DashMap::<String, String>::new());
    let watcher_state = file_state.clone();

    let tx_clone = tx.clone();
    let root_path = path.clone();
    
    let mut watcher = RecommendedWatcher::new(
        move |res: notify::Result<Event>| {
            if let Ok(event) = res {
                if event.kind.is_modify() || event.kind.is_create() {
                    for file_path in event.paths {
                        // Check .gitignore
                        if !gitignore.matched(&file_path, false).is_ignore() {
                            let path_str = file_path.to_string_lossy().into_owned();
                            
                            // PERFORMANCE PATCH: Ignore files larger than 50 MB
                            if let Ok(metadata) = std::fs::metadata(&file_path) {
                                if metadata.len() > 50_000_000 {
                                    println!("⚠️ Ignoring massive file: {} ({} bytes)", file_path.display(), metadata.len());
                                    continue;
                                }
                            }
                            
                            // Read it from disk.
                            if let Ok(content) = std::fs::read(&file_path) {
                                
                                // Compute hash of the current content
                                let mut hasher = DefaultHasher::new();
                                content.hash(&mut hasher);
                                let current_hash = hasher.finish();
                                
                                // Check if this hash matches what we just wrote from the network
                                if let Some(cached_hash) = watcher_hashes.get(&path_str) {
                                    if *cached_hash == current_hash {
                                        // This is an echo! The file content hasn't changed.
                                        continue;
                                    }
                                }
                                
                                // The content is genuinely new. Update our cache.
                                watcher_hashes.insert(path_str.clone(), current_hash);
                                
                                // Diffing Logic
                                let mut is_patch = false;
                                let mut final_payload = content.clone();
                                
                                if let Ok(new_text) = String::from_utf8(content.clone()) {
                                    if let Some(old_text) = watcher_state.get(&path_str) {
                                        let patch = diffy::create_patch(&old_text, &new_text);
                                        let patch_str = patch.to_string();
                                        
                                        // Only send patch if it's actually smaller than the file!
                                        if patch_str.len() < new_text.len() {
                                            is_patch = true;
                                            final_payload = patch_str.into_bytes();
                                        }
                                    }
                                    // Update state cache for next time
                                    watcher_state.insert(path_str.clone(), new_text);
                                }
                                
                                // Convert to relative path for the remote peer
                                if let Ok(rel_path) = file_path.strip_prefix(&root_path) {
                                    let rel_path_str = rel_path.to_string_lossy().into_owned();
                                    
                                    // Send over network channel
                                    let msg = network::SyncMessage {
                                        path: rel_path_str,
                                        is_patch,
                                        content: final_payload,
                                    };
                                    let _ = tx_clone.blocking_send(msg);
                                }
                            }
                        }
                    }
                }
            }
        },
        Config::default(),
    )?;

    watcher.watch(Path::new(&path), RecursiveMode::Recursive)?;

    match &cli.command {
        Commands::Host => {
            network::start_host(rx, file_hashes, file_state).await;
        }
        Commands::Join { ip } => {
            network::start_client(ip, rx, file_hashes, file_state).await;
        }
    }

    Ok(())
}
