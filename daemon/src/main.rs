use clap::{Parser, Subcommand};
use dashmap::DashMap;
use ignore::gitignore::{Gitignore, GitignoreBuilder};
use notify::event::{ModifyKind, RenameMode};
use notify::{Config, Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use teleport_daemon::crypto::Passphrase;
use teleport_daemon::network;
use teleport_daemon::proto::{FileBody, FileEvent};
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::sync::mpsc;

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    /// Folder to watch and synchronize.
    #[arg(long, short = 'f', global = true)]
    folder: Option<PathBuf>,

    /// TCP port to host on / connect to.
    #[arg(long, short = 'p', global = true, default_value_t = 8080)]
    port: u16,

    /// Pre-shared passphrase used to authenticate and key the encrypted
    /// channel. Required for `join`. Optional for `host` — if omitted,
    /// the host generates a fresh random one and prints it.
    #[arg(long, global = true)]
    passphrase: Option<String>,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Act as the host (listens for connections).
    Host,
    /// Connect to an existing host.
    Join {
        /// IP address of the host.
        ip: String,
    },
}

#[tokio::main]
async fn main() -> notify::Result<()> {
    let cli = Cli::parse();

    println!("Teleport Daemon v{}", env!("CARGO_PKG_VERSION"));

    // Resolve and validate the watch folder.
    let watch_root: PathBuf = cli
        .folder
        .clone()
        .unwrap_or_else(|| std::env::current_dir().expect("failed to read current dir"));

    let watch_root = match watch_root.canonicalize() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("❌ Cannot watch folder {}: {e}", watch_root.display());
            std::process::exit(2);
        }
    };
    if !watch_root.is_dir() {
        eprintln!("❌ Path is not a directory: {}", watch_root.display());
        std::process::exit(2);
    }

    println!("📁 Watching folder: {}", watch_root.display());
    println!("🔌 Using port: {}", cli.port);

    // Resolve passphrase.
    let passphrase = match (&cli.command, cli.passphrase.as_deref()) {
        (Commands::Host, Some(p)) => match Passphrase::parse(p) {
            Some(pw) => pw,
            None => {
                eprintln!("❌ Invalid passphrase format. Expected base32 (e.g. ABCDE-FGHIJ-KLMNO-PQRSTUV).");
                std::process::exit(2);
            }
        },
        (Commands::Host, None) => Passphrase::random(),
        (Commands::Join { .. }, Some(p)) => match Passphrase::parse(p) {
            Some(pw) => pw,
            None => {
                eprintln!("❌ Invalid --passphrase. Expected the code shown by the host (e.g. ABCDE-FGHIJ-KLMNO-PQRSTUV).");
                std::process::exit(2);
            }
        },
        (Commands::Join { .. }, None) => {
            eprintln!("❌ --passphrase is required for `join`. Ask the host for the code shown on its dashboard.");
            std::process::exit(2);
        }
    };

    // Build gitignore filter rooted at the watch folder.
    let gitignore = build_gitignore(&watch_root);

    let (tx, rx) = mpsc::channel::<FileEvent>(1024);

    let file_hashes = Arc::new(DashMap::<String, u64>::new());
    let file_state = Arc::new(DashMap::<String, String>::new());

    // Spawn the file system watcher. Filesystem events come in on a non-async
    // closure; we translate them into FileEvents and forward to the async
    // task via a blocking_send into the mpsc channel.
    let watch_root_clone = watch_root.clone();
    let watcher_hashes = file_hashes.clone();
    let watcher_state = file_state.clone();
    let watcher_tx = tx.clone();

    let mut watcher = RecommendedWatcher::new(
        move |res: notify::Result<Event>| {
            let event = match res {
                Ok(e) => e,
                Err(e) => {
                    eprintln!("⚠️  Watcher error: {e}");
                    return;
                }
            };

            for evt in translate_events(
                &event,
                &watch_root_clone,
                &gitignore,
                &watcher_hashes,
                &watcher_state,
            ) {
                if watcher_tx.blocking_send(evt).is_err() {
                    return;
                }
            }
        },
        Config::default(),
    )?;
    watcher.watch(Path::new(&watch_root), RecursiveMode::Recursive)?;

    // Wire the watcher → broadcast hub.
    let hub = network::PeerHub::new(watch_root.clone(), file_hashes, file_state);
    network::spawn_watcher_bridge(hub.clone(), rx);

    match &cli.command {
        Commands::Host => {
            network::start_host(cli.port, hub, passphrase).await;
        }
        Commands::Join { ip } => {
            network::start_client(ip, cli.port, hub, passphrase).await;
        }
    }
    Ok(())
}

fn build_gitignore(root: &Path) -> Gitignore {
    let mut builder = GitignoreBuilder::new(root);
    for line in [".git", "target", ".build", "node_modules", ".DS_Store"] {
        let _ = builder.add_line(None, line);
    }
    let gitignore_path = root.join(".gitignore");
    if gitignore_path.exists() {
        if let Some(err) = builder.add(&gitignore_path) {
            eprintln!("⚠️  Error parsing .gitignore: {err}");
        } else {
            println!("✅ Loaded .gitignore rules");
        }
    }
    builder.build().expect("gitignore build")
}

/// Translate one raw `notify::Event` into zero or more `FileEvent`s.
/// Encapsulates: ignore filtering, dedup against echoed writes, diff
/// computation, and the rename/delete branches that v0.3 was missing.
fn translate_events(
    event: &Event,
    root: &Path,
    gitignore: &Gitignore,
    hashes: &Arc<DashMap<String, u64>>,
    state: &Arc<DashMap<String, String>>,
) -> Vec<FileEvent> {
    let mut out = Vec::new();
    match &event.kind {
        EventKind::Create(_) | EventKind::Modify(ModifyKind::Data(_)) => {
            for path in &event.paths {
                if let Some(evt) = make_upsert(path, root, gitignore, hashes, state) {
                    out.push(evt);
                }
            }
        }
        EventKind::Modify(ModifyKind::Name(rename_mode)) => {
            // notify on macOS often pairs renames as a single event with two
            // paths and `RenameMode::Both`, but it can also fire `From`/`To`
            // separately. We handle the common case (Both) atomically and
            // fall back to delete-then-upsert for the others.
            match rename_mode {
                RenameMode::Both if event.paths.len() == 2 => {
                    let from = &event.paths[0];
                    let to = &event.paths[1];
                    if let (Some(from_rel), Some(to_rel)) =
                        (relativize(from, root), relativize(to, root))
                    {
                        if !gitignore.matched(from, false).is_ignore()
                            || !gitignore.matched(to, false).is_ignore()
                        {
                            // Move cached state with the rename.
                            let from_str = from.to_string_lossy().into_owned();
                            let to_str = to.to_string_lossy().into_owned();
                            if let Some((_, h)) = hashes.remove(&from_str) {
                                hashes.insert(to_str.clone(), h);
                            }
                            if let Some((_, s)) = state.remove(&from_str) {
                                state.insert(to_str, s);
                            }
                            out.push(FileEvent::Rename {
                                from: from_rel,
                                to: to_rel,
                            });
                        }
                    }
                }
                RenameMode::From => {
                    for path in &event.paths {
                        if let Some(evt) = make_delete(path, root, gitignore, hashes, state) {
                            out.push(evt);
                        }
                    }
                }
                RenameMode::To => {
                    for path in &event.paths {
                        if let Some(evt) = make_upsert(path, root, gitignore, hashes, state) {
                            out.push(evt);
                        }
                    }
                }
                // Catch-all (covers macOS's `Any`, `Other`, and any
                // `Both`-with-unexpected-arity edge case). FSEvents folds
                // rename events into `Any` because it can't tell which
                // path is source vs. destination — probe the file system:
                // if the path exists now it's the new location → Upsert;
                // if it doesn't, it was the old name → Delete.
                _ => {
                    for path in &event.paths {
                        if path.exists() {
                            if let Some(evt) = make_upsert(path, root, gitignore, hashes, state) {
                                out.push(evt);
                            }
                        } else if let Some(evt) = make_delete(path, root, gitignore, hashes, state) {
                            out.push(evt);
                        }
                    }
                }
            }
        }
        EventKind::Remove(_) => {
            for path in &event.paths {
                if let Some(evt) = make_delete(path, root, gitignore, hashes, state) {
                    out.push(evt);
                }
            }
        }
        _ => {}
    }
    out
}

fn make_upsert(
    path: &Path,
    root: &Path,
    gitignore: &Gitignore,
    hashes: &Arc<DashMap<String, u64>>,
    state: &Arc<DashMap<String, String>>,
) -> Option<FileEvent> {
    if gitignore.matched(path, false).is_ignore() {
        return None;
    }
    let metadata = std::fs::metadata(path).ok()?;
    if !metadata.is_file() {
        return None;
    }
    if metadata.len() > 50_000_000 {
        eprintln!(
            "⚠️  Skipping large file ({} bytes): {}",
            metadata.len(),
            path.display()
        );
        return None;
    }
    let content = std::fs::read(path).ok()?;
    let path_str = path.to_string_lossy().into_owned();

    let mut hasher = DefaultHasher::new();
    content.hash(&mut hasher);
    let current_hash = hasher.finish();
    if let Some(cached) = hashes.get(&path_str) {
        if *cached == current_hash {
            return None; // echo of a peer-driven write
        }
    }
    hashes.insert(path_str.clone(), current_hash);

    let body = if let Ok(new_text) = std::str::from_utf8(&content) {
        let new_text = new_text.to_string();
        let body = match state.get(&path_str) {
            Some(old_text) => {
                let patch = diffy::create_patch(&old_text, &new_text);
                let s = patch.to_string();
                if s.len() < new_text.len() {
                    FileBody::Patch(s)
                } else {
                    FileBody::Full(content.clone())
                }
            }
            None => FileBody::Full(content.clone()),
        };
        state.insert(path_str, new_text);
        body
    } else {
        state.remove(&path_str);
        FileBody::Full(content)
    };

    let rel = relativize(path, root)?;
    Some(FileEvent::Upsert { path: rel, body })
}

fn make_delete(
    path: &Path,
    root: &Path,
    gitignore: &Gitignore,
    hashes: &Arc<DashMap<String, u64>>,
    state: &Arc<DashMap<String, String>>,
) -> Option<FileEvent> {
    // We can't stat() a deleted file, so trust the path. Still, gate on
    // gitignore so we don't blast peer with deletes for ignored junk.
    if gitignore.matched(path, false).is_ignore() {
        return None;
    }
    let path_str = path.to_string_lossy().into_owned();
    hashes.remove(&path_str);
    state.remove(&path_str);
    let rel = relativize(path, root)?;
    if rel.is_empty() {
        return None;
    }
    Some(FileEvent::Delete { path: rel })
}

fn relativize(path: &Path, root: &Path) -> Option<String> {
    path.strip_prefix(root)
        .ok()
        .map(|r| r.to_string_lossy().replace('\\', "/"))
}
