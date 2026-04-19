import Foundation
import Security

/// Mirror of the Rust `Passphrase` type in `daemon/src/crypto.rs`.
///
/// 16 random bytes of entropy, displayed as base32-no-pad (Crockford-ish
/// alphabet, RFC 4648) split into four dash-separated groups for legibility:
///
///     ABCDE-FGHIJ-KLMNO-PQRSTUV
///
/// We generate the passphrase in Swift so the UI can show it to the user
/// immediately, then pass the *display form* to the daemon via
/// `--passphrase`. The daemon parses it identically.
struct Passphrase: Equatable {

    let raw: Data  // exactly 16 bytes

    /// Generate a fresh, cryptographically-random passphrase.
    static func random() -> Passphrase {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Passphrase(raw: Data(bytes))
    }

    /// Parse a user-typed passphrase. Tolerates whitespace, dashes, and
    /// any case. Returns `nil` if the cleaned input doesn't decode to 16
    /// bytes of base32.
    static func parse(_ input: String) -> Passphrase? {
        let cleaned = input
            .uppercased()
            .filter { $0 != "-" && !$0.isWhitespace }
        guard let data = base32Decode(cleaned), data.count == 16 else { return nil }
        return Passphrase(raw: data)
    }

    /// `XXXXX-XXXXX-XXXXX-XXXXXXXXXXX` — same split as the daemon side so
    /// the user sees identical text on both peers.
    var display: String {
        let encoded = base32Encode(raw)
        let chars = Array(encoded)
        precondition(chars.count == 26, "16-byte payload encodes to 26 base32 chars")
        return [
            String(chars[0..<5]),
            String(chars[5..<10]),
            String(chars[10..<15]),
            String(chars[15..<26]),
        ].joined(separator: "-")
    }
}

// MARK: - Base32 (RFC 4648, no padding)

private let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
private let base32Lookup: [Character: UInt8] = {
    var d = [Character: UInt8]()
    for (i, c) in base32Alphabet.enumerated() {
        d[c] = UInt8(i)
    }
    return d
}()

private func base32Encode(_ data: Data) -> String {
    var output = ""
    var buffer: UInt64 = 0
    var bitsLeft = 0
    for byte in data {
        buffer = (buffer << 8) | UInt64(byte)
        bitsLeft += 8
        while bitsLeft >= 5 {
            let index = Int((buffer >> (bitsLeft - 5)) & 0x1F)
            output.append(base32Alphabet[index])
            bitsLeft -= 5
        }
    }
    if bitsLeft > 0 {
        let index = Int((buffer << (5 - bitsLeft)) & 0x1F)
        output.append(base32Alphabet[index])
    }
    return output
}

private func base32Decode(_ input: String) -> Data? {
    var bytes = [UInt8]()
    var buffer: UInt64 = 0
    var bitsLeft = 0
    for ch in input {
        guard let value = base32Lookup[ch] else { return nil }
        buffer = (buffer << 5) | UInt64(value)
        bitsLeft += 5
        if bitsLeft >= 8 {
            let byte = UInt8((buffer >> (bitsLeft - 8)) & 0xFF)
            bytes.append(byte)
            bitsLeft -= 8
        }
    }
    return Data(bytes)
}
