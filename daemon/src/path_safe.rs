//! Defence against malicious or malformed paths arriving from a peer.
//!
//! v0.3 had a check for `..`, leading `/`, and leading `\\`. That's necessary
//! but nowhere near sufficient. A peer could:
//!   * Embed a NUL byte and hit the C-string boundary on macOS.
//!   * Use UNC `\\server\share` style.
//!   * Use a path with weird Unicode that normalises to `..` after NFC.
//!   * Race a write where the parent directory is replaced with a symlink
//!     pointing outside the root.
//!
//! `safe_join` answers a single yes/no question: *does this peer-supplied
//! relative path resolve to something that lives strictly under our watch
//! root, given the current state of the file system?*

use std::path::{Component, Path, PathBuf};

#[derive(Debug, PartialEq, Eq)]
pub enum PathError {
    Empty,
    Nul,
    NotRelative,
    ParentEscape,
    Escape(String),
}

impl std::fmt::Display for PathError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PathError::Empty => write!(f, "path was empty"),
            PathError::Nul => write!(f, "path contained a NUL byte"),
            PathError::NotRelative => write!(f, "path was absolute or had a Windows prefix"),
            PathError::ParentEscape => write!(f, "path component '..' is not allowed"),
            PathError::Escape(p) => write!(f, "path '{}' resolves outside the watch root", p),
        }
    }
}

impl std::error::Error for PathError {}

/// Validate `rel` and return a path guaranteed to live under `root`.
///
/// Lexical checks happen first (cheap, deterministic, no I/O). After that
/// we walk the resulting absolute path through the file system and make
/// sure its real, canonicalised location is still inside `root`.
///
/// `root` MUST be an already-canonicalised absolute path (the daemon does
/// this once on startup).
pub fn safe_join(root: &Path, rel: &str) -> Result<PathBuf, PathError> {
    if rel.is_empty() {
        return Err(PathError::Empty);
    }
    if rel.contains('\0') {
        return Err(PathError::Nul);
    }

    let candidate = Path::new(rel);

    for comp in candidate.components() {
        match comp {
            Component::Normal(_) | Component::CurDir => {}
            Component::ParentDir => return Err(PathError::ParentEscape),
            Component::RootDir | Component::Prefix(_) => return Err(PathError::NotRelative),
        }
    }

    let joined = root.join(candidate);

    // Canonicalise the deepest existing ancestor, then re-attach the tail
    // that doesn't exist yet. This catches symlink-based escapes for
    // existing files without failing for not-yet-created ones.
    let resolved = resolve_within(root, &joined)?;
    if !resolved.starts_with(root) {
        return Err(PathError::Escape(rel.to_string()));
    }
    Ok(resolved)
}

fn resolve_within(root: &Path, joined: &Path) -> Result<PathBuf, PathError> {
    let mut existing: PathBuf = joined.to_path_buf();
    let mut tail: Vec<std::ffi::OsString> = Vec::new();

    loop {
        match existing.canonicalize() {
            Ok(c) => {
                let mut out = c;
                for seg in tail.into_iter().rev() {
                    out.push(seg);
                }
                return Ok(out);
            }
            Err(_) => match existing.file_name() {
                Some(name) => {
                    tail.push(name.to_os_string());
                    if !existing.pop() {
                        return Err(PathError::Escape(joined.display().to_string()));
                    }
                }
                None => {
                    // Walked off the top — root itself didn't canonicalise,
                    // which means caller passed a non-existent root.
                    return Err(PathError::Escape(root.display().to_string()));
                }
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn root() -> (TempDir, PathBuf) {
        let dir = TempDir::new().unwrap();
        let canon = dir.path().canonicalize().unwrap();
        (dir, canon)
    }

    #[test]
    fn allows_simple_relative_path() {
        let (_d, root) = root();
        let p = safe_join(&root, "a/b/c.txt").unwrap();
        assert!(p.starts_with(&root));
        assert!(p.ends_with("c.txt"));
    }

    #[test]
    fn rejects_empty() {
        let (_d, root) = root();
        assert_eq!(safe_join(&root, ""), Err(PathError::Empty));
    }

    #[test]
    fn rejects_nul() {
        let (_d, root) = root();
        assert_eq!(safe_join(&root, "a\0b"), Err(PathError::Nul));
    }

    #[test]
    fn rejects_absolute() {
        let (_d, root) = root();
        assert_eq!(safe_join(&root, "/etc/passwd"), Err(PathError::NotRelative));
    }

    #[test]
    fn rejects_dotdot() {
        let (_d, root) = root();
        assert_eq!(safe_join(&root, "../boom"), Err(PathError::ParentEscape));
        assert_eq!(safe_join(&root, "a/../../boom"), Err(PathError::ParentEscape));
    }

    #[test]
    fn rejects_symlink_escape() {
        let (_d, root) = root();
        // Make a symlink inside root that points outside root.
        let outside = TempDir::new().unwrap();
        let link = root.join("escape-link");
        std::os::unix::fs::symlink(outside.path(), &link).unwrap();

        let result = safe_join(&root, "escape-link/secret.txt");
        assert!(matches!(result, Err(PathError::Escape(_))));
    }

    #[test]
    fn allows_path_into_existing_subdir() {
        let (_d, root) = root();
        fs::create_dir_all(root.join("sub")).unwrap();
        let p = safe_join(&root, "sub/file.txt").unwrap();
        assert!(p.starts_with(&root));
    }
}
