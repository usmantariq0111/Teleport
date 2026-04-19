mod network;

use clap::{Parser, Subcommand};
use notify::{Config, Event, RecommendedWatcher, RecursiveMode, Watcher};
use std::path::Path;
use tokio::sync::mpsc;
use ignore::gitignore::GitignoreBuilder;

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

    // Parse the .gitignore file if it exists
    let gitignore_path = path.join(".gitignore");
    let mut builder = GitignoreBuilder::new(&path);
    
    // Always ignore critical directories to prevent infinite loops
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
    
    // Build the gitignore object
    let gitignore = builder.build().unwrap().clone();

    // Create an async channel to pass file events to the network layer
    let (tx, rx) = mpsc::channel::<String>(100);

    // Set up the FSEvents watcher
    let tx_clone = tx.clone();
    let mut watcher = RecommendedWatcher::new(
        move |res: notify::Result<Event>| {
            if let Ok(event) = res {
                if event.kind.is_modify() || event.kind.is_create() {
                    for file_path in event.paths {
                        // Dynamically check against the .gitignore rules
                        if !gitignore.matched(&file_path, false).is_ignore() {
                            let path_str = file_path.to_string_lossy();
                            let _ = tx_clone.blocking_send(path_str.into_owned());
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
            network::start_host(rx).await;
        }
        Commands::Join { ip } => {
            network::start_client(ip, rx).await;
        }
    }

    Ok(())
}
