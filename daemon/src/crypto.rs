//! Authenticated, encrypted transport built on the Noise Protocol.
//!
//! ## Threat model
//! A peer on the same LAN (or anyone on the path between the two peers)
//! must not be able to:
//!   * Read file contents in transit.
//!   * Inject or modify file events.
//!   * Connect at all without knowing a shared secret out-of-band.
//!
//! ## Design
//! We use the Noise pattern `Noise_NNpsk0_25519_ChaChaPoly_BLAKE2s`:
//!   * **NN** — neither side has a long-lived static key. Ephemeral DH only.
//!     Perfect-forward-secrecy by default.
//!   * **psk0** — the pre-shared key is mixed in *before* the handshake's
//!     first message, so a wrong PSK fails immediately without revealing
//!     anything to the attacker.
//!   * **ChaChaPoly + BLAKE2s** — modern AEAD + fast hash, no special CPU
//!     features required.
//!
//! The PSK presented to the user is a 16-byte random secret, base32-encoded
//! into 26 ASCII chars and split into four chunks for readability:
//!     `XXXXX-XXXXX-XXXXX-XXXXXXXXXXX`
//! 16 bytes = 128 bits of entropy. We then run HKDF-SHA256 with a static
//! info string to derive the 32-byte PSK that Noise consumes.
//!
//! On the wire, after the 2-message handshake, every frame is:
//!     `[u32 BE length][AEAD ciphertext]`
//! Each frame is at most `MAX_FRAME_BYTES` (see proto.rs).

use data_encoding::BASE32_NOPAD;
use hkdf::Hkdf;
use rand::RngCore;
use sha2::Sha256;
use snow::{Builder, HandshakeState, TransportState};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use zeroize::{Zeroize, ZeroizeOnDrop};

use crate::proto::MAX_FRAME_BYTES;

const NOISE_PARAMS: &str = "Noise_NNpsk0_25519_ChaChaPoly_BLAKE2s";
const HKDF_INFO: &[u8] = b"teleport.psk.v1";
const PSK_RAW_BYTES: usize = 16;

/// User-visible passphrase. Wraps the raw bytes plus a friendly display form.
///
/// `ZeroizeOnDrop` ensures the secret bytes are wiped from the heap as soon
/// as the value goes out of scope, instead of waiting for the allocator to
/// hand the page back out to some unrelated allocation.
#[derive(Clone, Zeroize, ZeroizeOnDrop)]
pub struct Passphrase {
    raw: [u8; PSK_RAW_BYTES],
}

impl Passphrase {
    /// Generate a fresh random passphrase.
    pub fn random() -> Self {
        let mut raw = [0u8; PSK_RAW_BYTES];
        rand::rngs::OsRng.fill_bytes(&mut raw);
        Self { raw }
    }

    /// Parse a user-entered passphrase. Strips dashes / whitespace, accepts
    /// any case. Returns `None` if it doesn't decode to the right length.
    pub fn parse(input: &str) -> Option<Self> {
        let cleaned: String = input
            .chars()
            .filter(|c| !c.is_whitespace() && *c != '-')
            .map(|c| c.to_ascii_uppercase())
            .collect();
        let bytes = BASE32_NOPAD.decode(cleaned.as_bytes()).ok()?;
        if bytes.len() != PSK_RAW_BYTES {
            return None;
        }
        let mut raw = [0u8; PSK_RAW_BYTES];
        raw.copy_from_slice(&bytes);
        Some(Self { raw })
    }

    /// Pretty form: four dash-separated chunks of base32.
    pub fn display(&self) -> String {
        let encoded = BASE32_NOPAD.encode(&self.raw);
        // 16 bytes → 26 base32 chars. Split 5-5-5-11.
        let bytes = encoded.as_bytes();
        format!(
            "{}-{}-{}-{}",
            std::str::from_utf8(&bytes[0..5]).unwrap(),
            std::str::from_utf8(&bytes[5..10]).unwrap(),
            std::str::from_utf8(&bytes[10..15]).unwrap(),
            std::str::from_utf8(&bytes[15..]).unwrap(),
        )
    }

    /// Derive the 32-byte Noise PSK via HKDF-SHA256.
    pub fn derive_psk(&self) -> [u8; 32] {
        let hk = Hkdf::<Sha256>::new(None, &self.raw);
        let mut out = [0u8; 32];
        hk.expand(HKDF_INFO, &mut out)
            .expect("HKDF expand to 32 bytes never fails");
        out
    }
}

/// Wraps a `TcpStream` after a successful Noise handshake. Provides
/// length-prefixed encrypted frame I/O.
pub struct EncryptedStream {
    inner: TcpStream,
    transport: TransportState,
    /// Reusable scratch space to avoid per-frame allocations.
    cipher_buf: Vec<u8>,
    plain_buf: Vec<u8>,
}

impl EncryptedStream {
    /// Run the Noise handshake as the **initiator** (joiner). Returns the
    /// authenticated stream once both sides agree on the PSK.
    pub async fn handshake_initiator(
        mut sock: TcpStream,
        passphrase: &Passphrase,
    ) -> std::io::Result<Self> {
        let psk = passphrase.derive_psk();
        let mut hs = build_handshake(&psk, true)?;

        // -> e, psk
        let mut buf = [0u8; 1024];
        let len = hs
            .write_message(&[], &mut buf)
            .map_err(noise_io)?;
        write_frame(&mut sock, &buf[..len]).await?;

        // <- e, ee
        let frame = read_frame(&mut sock).await?;
        hs.read_message(&frame, &mut buf).map_err(noise_io)?;

        let transport = hs.into_transport_mode().map_err(noise_io)?;
        Ok(Self::new(sock, transport))
    }

    /// Run the Noise handshake as the **responder** (host).
    pub async fn handshake_responder(
        mut sock: TcpStream,
        passphrase: &Passphrase,
    ) -> std::io::Result<Self> {
        let psk = passphrase.derive_psk();
        let mut hs = build_handshake(&psk, false)?;

        // <- e, psk
        let frame = read_frame(&mut sock).await?;
        let mut scratch = [0u8; 1024];
        hs.read_message(&frame, &mut scratch).map_err(noise_io)?;

        // -> e, ee
        let len = hs
            .write_message(&[], &mut scratch)
            .map_err(noise_io)?;
        write_frame(&mut sock, &scratch[..len]).await?;

        let transport = hs.into_transport_mode().map_err(noise_io)?;
        Ok(Self::new(sock, transport))
    }

    fn new(inner: TcpStream, transport: TransportState) -> Self {
        Self {
            inner,
            transport,
            cipher_buf: Vec::with_capacity(8 * 1024),
            plain_buf: Vec::with_capacity(8 * 1024),
        }
    }

    /// Encrypt and send one application frame.
    pub async fn send(&mut self, plaintext: &[u8]) -> std::io::Result<()> {
        // Noise's hard ceiling on a single transport message is 65,535
        // bytes *including* the 16-byte AEAD tag, so per-chunk plaintext
        // must be at most 65,519. We cap conservatively at 65,000 to leave
        // headroom for any future framing tweaks.
        const NOISE_PLAINTEXT_MAX: usize = 65_000;

        // Compute chunk count without iterating twice (the previous version
        // walked `plaintext.chunks()` once for `len()` and again for the
        // encrypt loop).
        let n_chunks = if plaintext.is_empty() {
            1
        } else {
            (plaintext.len() + NOISE_PLAINTEXT_MAX - 1) / NOISE_PLAINTEXT_MAX
        } as u32;

        self.cipher_buf.clear();
        self.cipher_buf.extend_from_slice(&n_chunks.to_be_bytes());

        let mut tmp = vec![0u8; NOISE_PLAINTEXT_MAX + 16];
        if plaintext.is_empty() {
            let len = self
                .transport
                .write_message(&[], &mut tmp)
                .map_err(noise_io)?;
            self.cipher_buf.extend_from_slice(&(len as u32).to_be_bytes());
            self.cipher_buf.extend_from_slice(&tmp[..len]);
            return write_frame(&mut self.inner, &self.cipher_buf).await;
        }
        for chunk in plaintext.chunks(NOISE_PLAINTEXT_MAX) {
            let len = self
                .transport
                .write_message(chunk, &mut tmp)
                .map_err(noise_io)?;
            self.cipher_buf.extend_from_slice(&(len as u32).to_be_bytes());
            self.cipher_buf.extend_from_slice(&tmp[..len]);
        }
        write_frame(&mut self.inner, &self.cipher_buf).await
    }

    /// Read one application frame and decrypt it.
    pub async fn recv(&mut self) -> std::io::Result<Vec<u8>> {
        let frame = read_frame(&mut self.inner).await?;
        if frame.len() < 4 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "encrypted frame too short",
            ));
        }
        let n_chunks = u32::from_be_bytes(frame[0..4].try_into().unwrap()) as usize;
        let mut cursor = 4usize;

        self.plain_buf.clear();
        let mut tmp = vec![0u8; 65_535];
        for _ in 0..n_chunks {
            if cursor + 4 > frame.len() {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "truncated chunk header",
                ));
            }
            let clen = u32::from_be_bytes(frame[cursor..cursor + 4].try_into().unwrap()) as usize;
            cursor += 4;
            if cursor + clen > frame.len() {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "truncated chunk body",
                ));
            }
            let plen = self
                .transport
                .read_message(&frame[cursor..cursor + clen], &mut tmp)
                .map_err(noise_io)?;
            self.plain_buf.extend_from_slice(&tmp[..plen]);
            cursor += clen;
        }
        Ok(std::mem::take(&mut self.plain_buf))
    }
}

fn build_handshake(psk: &[u8; 32], initiator: bool) -> std::io::Result<HandshakeState> {
    let builder = Builder::new(NOISE_PARAMS.parse().expect("static noise params parse"))
        .psk(0, psk);
    let hs = if initiator {
        builder.build_initiator()
    } else {
        builder.build_responder()
    };
    hs.map_err(noise_io)
}

fn noise_io(e: snow::Error) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::Other, format!("noise: {e}"))
}

async fn write_frame(sock: &mut TcpStream, payload: &[u8]) -> std::io::Result<()> {
    if payload.len() > MAX_FRAME_BYTES {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "outbound frame exceeds MAX_FRAME_BYTES",
        ));
    }
    let len = payload.len() as u32;
    sock.write_all(&len.to_be_bytes()).await?;
    sock.write_all(payload).await
}

async fn read_frame(sock: &mut TcpStream) -> std::io::Result<Vec<u8>> {
    let mut len_buf = [0u8; 4];
    sock.read_exact(&mut len_buf).await?;
    let len = u32::from_be_bytes(len_buf) as usize;
    if len > MAX_FRAME_BYTES {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("peer sent oversized frame: {len} bytes"),
        ));
    }
    let mut buf = vec![0u8; len];
    sock.read_exact(&mut buf).await?;
    Ok(buf)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn passphrase_round_trips() {
        let p = Passphrase::random();
        let display = p.display();
        let parsed = Passphrase::parse(&display).expect("display should parse");
        assert_eq!(p.raw, parsed.raw);
    }

    #[test]
    fn passphrase_accepts_lowercase_and_extra_dashes() {
        let p = Passphrase::random();
        let mangled = p.display().to_lowercase().replace('-', " - ");
        let parsed = Passphrase::parse(&mangled).expect("should still parse");
        assert_eq!(p.raw, parsed.raw);
    }

    #[test]
    fn passphrase_rejects_garbage() {
        assert!(Passphrase::parse("not a real passphrase!").is_none());
        assert!(Passphrase::parse("").is_none());
        assert!(Passphrase::parse("AAAA").is_none()); // too short
    }

    #[test]
    fn psk_is_deterministic_and_distinct() {
        let p1 = Passphrase::random();
        let p2 = Passphrase::random();
        assert_eq!(p1.derive_psk(), p1.derive_psk());
        assert_ne!(p1.derive_psk(), p2.derive_psk());
        assert_eq!(p1.derive_psk().len(), 32);
    }

    #[tokio::test]
    async fn end_to_end_handshake_and_frame() {
        use tokio::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let pw = Passphrase::random();
        let pw_a = pw.clone();
        let pw_b = pw.clone();

        let server = tokio::spawn(async move {
            let (sock, _) = listener.accept().await.unwrap();
            let mut s = EncryptedStream::handshake_responder(sock, &pw_a).await.unwrap();
            let msg = s.recv().await.unwrap();
            assert_eq!(msg, b"hello".to_vec());
            s.send(b"world").await.unwrap();
        });

        let sock = TcpStream::connect(addr).await.unwrap();
        let mut c = EncryptedStream::handshake_initiator(sock, &pw_b).await.unwrap();
        c.send(b"hello").await.unwrap();
        let reply = c.recv().await.unwrap();
        assert_eq!(reply, b"world".to_vec());

        server.await.unwrap();
    }

    #[tokio::test]
    async fn wrong_passphrase_fails_handshake() {
        use tokio::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server_pw = Passphrase::random();
        let client_pw = Passphrase::random();

        let server = tokio::spawn(async move {
            let (sock, _) = listener.accept().await.unwrap();
            EncryptedStream::handshake_responder(sock, &server_pw).await.err()
        });

        let sock = TcpStream::connect(addr).await.unwrap();
        let result = EncryptedStream::handshake_initiator(sock, &client_pw).await;
        assert!(result.is_err());
        let _ = server.await.unwrap();
    }

    #[tokio::test]
    async fn large_frame_round_trip() {
        use tokio::net::TcpListener;

        // 200 KB — forces multi-chunk encryption (Noise max is 64 KB per chunk).
        let payload = vec![0xAB; 200 * 1024];
        let payload_clone = payload.clone();

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let pw = Passphrase::random();
        let pw_a = pw.clone();
        let pw_b = pw.clone();

        let server = tokio::spawn(async move {
            let (sock, _) = listener.accept().await.unwrap();
            let mut s = EncryptedStream::handshake_responder(sock, &pw_a).await.unwrap();
            let got = s.recv().await.unwrap();
            assert_eq!(got, payload_clone);
        });

        let sock = TcpStream::connect(addr).await.unwrap();
        let mut c = EncryptedStream::handshake_initiator(sock, &pw_b).await.unwrap();
        c.send(&payload).await.unwrap();

        server.await.unwrap();
    }
}
