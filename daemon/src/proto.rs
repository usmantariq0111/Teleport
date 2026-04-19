//! Wire protocol for Teleport.
//!
//! All on-the-wire messages are `FileEvent` values, encoded with bincode
//! (compact, schema-evolution-safe via `bincode::config::standard()` style),
//! then encrypted by the Noise transport in `crypto.rs`, then framed with a
//! 4-byte big-endian length prefix on the TCP stream.
//!
//! v0.3 used JSON. We switched to bincode in v0.4 because:
//!   * Binary files no longer balloon ~5x (JSON encodes Vec<u8> as a numeric
//!     array). bincode writes raw bytes.
//!   * Slightly faster, no UTF-8 validation needed for content.
//!   * Versioning is enforced explicitly by `PROTOCOL_VERSION` below.

use serde::{Deserialize, Serialize};

/// Bumped any time the wire format changes incompatibly.
pub const PROTOCOL_VERSION: u32 = 1;

/// Hard upper bound on a single decrypted frame. Anything larger is treated
/// as a hostile / corrupted peer and the connection is closed.
///
/// The watcher already refuses to *send* anything > 50 MB; we leave headroom
/// for bincode and Noise overhead.
pub const MAX_FRAME_BYTES: usize = 64 * 1024 * 1024;

/// One file-system change.
#[derive(Serialize, Deserialize, Debug, Clone)]
pub enum FileEvent {
    /// Create or modify `path` (relative to the watch root).
    Upsert { path: String, body: FileBody },
    /// Delete `path`.
    Delete { path: String },
    /// Rename `from` → `to` (both relative to the watch root).
    Rename { from: String, to: String },
}

/// Payload variant for `Upsert`. We send a unified-diff patch when both peers
/// already agree on the prior text version (much smaller); otherwise we send
/// the full byte snapshot. Binary files always use `Full`.
#[derive(Serialize, Deserialize, Debug, Clone)]
pub enum FileBody {
    Full(Vec<u8>),
    Patch(String),
}

impl FileEvent {
    /// Path the event mutates. For `Rename` this is the *destination*, since
    /// that's what gets created on the receiving side.
    pub fn primary_path(&self) -> &str {
        match self {
            FileEvent::Upsert { path, .. } => path,
            FileEvent::Delete { path } => path,
            FileEvent::Rename { to, .. } => to,
        }
    }
}

/// Convenience: encode an event into bincode bytes.
pub fn encode(event: &FileEvent) -> bincode::Result<Vec<u8>> {
    bincode::serialize(event)
}

/// Convenience: decode an event from bincode bytes.
pub fn decode(bytes: &[u8]) -> bincode::Result<FileEvent> {
    bincode::deserialize(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn upsert_full_round_trip_preserves_binary_bytes() {
        // Bytes that would be invalid UTF-8 — the JSON path used to balloon
        // these into a numeric array. bincode keeps them as-is.
        let raw = vec![0xFFu8, 0x00, 0xC0, 0x80, 0xDE, 0xAD, 0xBE, 0xEF];
        let evt = FileEvent::Upsert {
            path: "img.png".into(),
            body: FileBody::Full(raw.clone()),
        };

        let bytes = encode(&evt).unwrap();
        let decoded = decode(&bytes).unwrap();
        match decoded {
            FileEvent::Upsert { path, body: FileBody::Full(got) } => {
                assert_eq!(path, "img.png");
                assert_eq!(got, raw);
            }
            other => panic!("wrong variant: {:?}", other),
        }
    }

    #[test]
    fn delete_round_trip() {
        let evt = FileEvent::Delete { path: "old.txt".into() };
        let decoded = decode(&encode(&evt).unwrap()).unwrap();
        assert!(matches!(decoded, FileEvent::Delete { path } if path == "old.txt"));
    }

    #[test]
    fn rename_round_trip() {
        let evt = FileEvent::Rename {
            from: "a.md".into(),
            to: "b.md".into(),
        };
        let decoded = decode(&encode(&evt).unwrap()).unwrap();
        match decoded {
            FileEvent::Rename { from, to } => {
                assert_eq!(from, "a.md");
                assert_eq!(to, "b.md");
            }
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn primary_path_picks_destination_for_rename() {
        let evt = FileEvent::Rename {
            from: "a".into(),
            to: "b".into(),
        };
        assert_eq!(evt.primary_path(), "b");
    }
}
