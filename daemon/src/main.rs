mod network;

use clap::{Parser, Subcommand};
use dashmap::DashMap;
use ignore::gitignore::GitignoreBuilder;
use notify::{Config, Event, RecommendedWatcher, RecursiveMode, Watcher};
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

    // The channel now passes the complex SyncMessage structure
    let (tx, rx) = mpsc::channel::<network::SyncMessage>(100);

    // The Ignore Cache prevents infinite echo loops
    let ignore_cache = Arc::new(DashMap::<String, bool>::new());
    let watcher_cache = ignore_cache.clone();

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
                            
                            // Prevent echo loop: Is this file from the network?
                            if watcher_cache.remove(&path_str).is_some() {
                                continue;
                            }
                            
                            // Genuine local change. Read it from disk.
                            if let Ok(content) = std::fs::read(&file_path) {
                                // Convert to relative path for the remote peer
                                if let Ok(rel_path) = file_path.strip_prefix(&root_path) {
                                    let rel_path_str = rel_path.to_string_lossy().into_owned();
                                    
                                    // Send over network channel
                                    let msg = network::SyncMessage {
                                        path: rel_path_str,
                                        content,
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
            network::start_host(rx, ignore_cache).await;
        }
        Commands::Join { ip } => {
            network::start_client(ip, rx, ignore_cache).await;
        }
    }

    Ok(())
}
