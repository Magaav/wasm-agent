//! Reading an ed25519 signing key out of a file: `wa vault import-ed25519 <name> --from <path>`.
//!
//! The file an operator actually has is not always 32 raw bytes. `wa fleet keygen` writes the fleet
//! key as **pkcs8 hex** (the same format as `node.key`, `rust/wa-mesh/src/identity.rs`), because that
//! is what `wa fleet sign --key <path>` reads; a hand-made key may be a raw 32-byte seed; a key copied
//! out of a password manager may be 64 hex characters. All three name the same thing, and refusing the
//! one the operator's own tool wrote would have made "put the fleet key in the vault" a two-step
//! conversion nobody documented. So this reads all three, and says which one it read.
//!
//! It only ever answers a **seed** (32 bytes). A pkcs8 document carries a public key too; that is
//! dropped, because `Ed25519` entries in the vault store a seed and derive the public half on demand
//! (`Vault::public_key`). Nothing here prints or logs the bytes, and the caller (`cli.rs`) writes only
//! the *public* key to the terminal.
//!
//! The extraction is not a guess: a candidate is accepted only when it re-derives exactly the public
//! key the pkcs8 document carries, so an unrelated 32-byte window in a bigger DER structure cannot be
//! mistaken for the seed.

use crate::hex;

/// How the file was read. Reported to the operator (it is a format name, not a secret).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Format {
    /// 32 bytes, not hex: a bare seed.
    RawSeed,
    /// 64 hex characters: the same seed, written as text.
    HexSeed,
    /// pkcs8 hex: what `wa fleet keygen` and a node's `node.key` hold.
    Pkcs8Hex,
}

impl Format {
    pub fn as_str(&self) -> &'static str {
        match self {
            Format::RawSeed => "raw-seed",
            Format::HexSeed => "hex-seed",
            Format::Pkcs8Hex => "pkcs8-hex",
        }
    }
}

/// The bytes of a seed file, without the trailing newline an editor or `wa fleet keygen` leaves.
fn trimmed(bytes: &[u8]) -> &[u8] {
    let mut end = bytes.len();
    while end > 0 && matches!(bytes[end - 1], b'\n' | b'\r' | b' ' | b'\t') {
        end -= 1;
    }
    &bytes[..end]
}

/// Read a seed out of the bytes of a key file.
///
/// A file that is 32 bytes and *not* all hex digits is a raw seed; anything else is read as hex, which
/// is either a seed (32 bytes) or a pkcs8 document (whose seed is extracted). Every other length is
/// `vault_seed_length` with the length in the message: the length of a *key file* is not a secret, and
/// an operator who copied half a key needs to know that is what happened.
pub fn read(bytes: &[u8]) -> Result<([u8; 32], Format), String> {
    let bytes = trimmed(bytes);
    if bytes.is_empty() {
        return Err("vault_seed_empty".to_string());
    }
    let text = std::str::from_utf8(bytes).ok();
    let all_hex = text.is_some_and(|text| text.bytes().all(|byte| byte.is_ascii_hexdigit()));
    if bytes.len() == 32 && !all_hex {
        let mut seed = [0u8; 32];
        seed.copy_from_slice(bytes);
        return Ok((seed, Format::RawSeed));
    }
    let Some(text) = text.filter(|_| all_hex) else {
        return Err(format!("vault_seed_length:{} (not hex, and not a 32-byte seed)", bytes.len()));
    };
    let der = hex::decode(text).ok_or_else(|| format!("vault_seed_length:{} (odd hex)", text.len()))?;
    match der.len() {
        32 => {
            let mut seed = [0u8; 32];
            seed.copy_from_slice(&der);
            Ok((seed, Format::HexSeed))
        }
        // pkcs8: 48 bytes (v1) or 64+ bytes (v2, with the public key appended).
        48..=128 => Ok((seed_from_pkcs8(&der)?, Format::Pkcs8Hex)),
        other => Err(format!("vault_seed_length:{other}")),
    }
}

/// The seed inside a pkcs8 ed25519 document.
///
/// `ring` validates the document (so a corrupt one is `vault_seed_invalid` before a candidate is
/// looked at) and the candidate window is accepted only when it derives the document's public key.
fn seed_from_pkcs8(der: &[u8]) -> Result<[u8; 32], String> {
    use ring::signature::{Ed25519KeyPair, KeyPair};
    let keypair =
        Ed25519KeyPair::from_pkcs8(der).map_err(|_| "vault_seed_invalid: not a pkcs8 ed25519 key".to_string())?;
    let public = keypair.public_key().as_ref().to_vec();
    // RFC 8410 wraps the 32-byte seed as `04 20 <seed>` inside the privateKey OCTET STRING. Scanning
    // for that header and then *proving* the candidate is the only way to be sure in a document whose
    // version adds fields: a v2 key carries the public key too, so the window is not at a fixed offset.
    let mut start = 0;
    while start + 34 <= der.len() {
        if der[start] == 0x04 && der[start + 1] == 0x20 {
            let candidate = &der[start + 2..start + 34];
            if Ed25519KeyPair::from_seed_unchecked(candidate)
                .map(|pair| pair.public_key().as_ref() == public.as_slice())
                .unwrap_or(false)
            {
                let mut seed = [0u8; 32];
                seed.copy_from_slice(candidate);
                return Ok(seed);
            }
        }
        start += 1;
    }
    Err("vault_seed_invalid: the pkcs8 document carries no seed this key reproduces".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use ring::rand::SystemRandom;
    use ring::signature::{Ed25519KeyPair, KeyPair};

    /// A fresh pkcs8 document and the seed inside it, so every form below is the same key.
    fn document_and_seed() -> (Vec<u8>, [u8; 32]) {
        let document = Ed25519KeyPair::generate_pkcs8(&SystemRandom::new()).unwrap();
        let seed = seed_from_pkcs8(document.as_ref()).expect("the seed of a fresh document");
        (document.as_ref().to_vec(), seed)
    }

    #[test]
    fn a_raw_seed_a_hex_seed_and_a_pkcs8_document_all_read_the_same_key() {
        let (der, seed) = document_and_seed();
        let (from_raw, format) = read(&seed).expect("raw");
        assert_eq!((from_raw, format), (seed, Format::RawSeed));

        let (from_hex, format) = read(format!("{}
", hex::encode(&seed)).as_bytes()).expect("hex");
        assert_eq!((from_hex, format), (seed, Format::HexSeed));

        // `wa fleet keygen` writes exactly this: pkcs8 hex, one trailing newline.
        let (from_pkcs8, format) = read(format!("{}
", hex::encode(&der)).as_bytes()).expect("pkcs8");
        assert_eq!((from_pkcs8, format), (seed, Format::Pkcs8Hex));
        // What it answered really is that document's key: the public halves agree.
        let expected = Ed25519KeyPair::from_pkcs8(&der).unwrap();
        let derived = Ed25519KeyPair::from_seed_unchecked(&from_pkcs8).unwrap();
        assert_eq!(derived.public_key().as_ref(), expected.public_key().as_ref());
    }

    #[test]
    fn a_file_of_the_wrong_shape_is_refused_by_name_and_its_length_without_echoing_any_bytes() {
        assert_eq!(read(b"").unwrap_err(), "vault_seed_empty");
        // 31 raw bytes: not a seed, not hex.
        let short = vec![0x01u8; 31];
        assert_eq!(read(&short).unwrap_err().split(':').next().unwrap(), "vault_seed_length");
        assert!(!read(&short).unwrap_err().contains(&hex::encode(&short[..2])));
        // 16 bytes of hex is not a seed either.
        assert!(read(b"00112233445566778899aabbccddeeff").is_err());
        // Hex-looking text that is not a pkcs8 document: refused, never "close enough".
        let garbage = hex::encode(&[0x41u8; 60]);
        assert!(read(garbage.as_bytes()).unwrap_err().starts_with("vault_seed_invalid"));
    }
}
