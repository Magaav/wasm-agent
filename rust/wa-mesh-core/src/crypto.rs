//! Hex, sha256, and the one thing a build has to supply itself: an ed25519 *verifier*.
//!
//! The mesh's logic needs three crypto primitives and nothing else: a hex codec, sha256 (node ids are
//! `sha256(public_key)[..32]`, a roster's fingerprint is `sha256(canonical)[..16]`, and the attestation
//! binds `sha256(material)`), and an ed25519 verify. The first two are the same bytes in every build, so
//! they are here. The third is a *build input*: the node has ring (one identity, one key, already in the
//! process) and the `wa:mesh` guest has a pure-Rust ed25519 (a component cannot link ring's C and
//! assembly). Both are ed25519 as specified, so a signature one accepts, the other accepts.
//!
//! What this crate deliberately does **not** have: a signer. Signing needs a private key, and no code
//! on this side of the split may invent one -- the node's identity stays the node's, and the guest
//! never holds a key (the host signs; the guest only builds the bytes and verifies them).
use sha2::{Digest, Sha256};

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

pub fn unhex(text: &str) -> Option<Vec<u8>> {
    let text = text.trim();
    if !text.is_ascii() || !text.len().is_multiple_of(2) {
        return None;
    }
    (0..text.len() / 2)
        .map(|index| u8::from_str_radix(&text[index * 2..index * 2 + 2], 16).ok())
        .collect()
}

/// SHA-256 of a string, as hex. Every signed message in the mesh signs a hash of the bytes it is about,
/// so what was signed is what was asked for and not merely that something was.
pub fn sha256_hex(text: &str) -> String {
    sha256_bytes_hex(text.as_bytes())
}

pub fn sha256_bytes_hex(bytes: &[u8]) -> String {
    hex(Sha256::digest(bytes).as_ref())
}

/// The node id a public key answers to: the first 32 hex characters of `sha256(public_key)`.
///
/// This is why a roster entry can be checked at all: an entry that claims a `node_id` its `public_key`
/// does not hash to is a typo or an attack, and either way it is refused.
pub fn derive_node_id(public_key_hex: &str) -> Option<String> {
    let public = unhex(public_key_hex)?;
    Some(sha256_bytes_hex(&public)[..32].to_string())
}

/// The ed25519 verify a build supplies. Stateless on purpose: a verifier holds no key, so a `Crypto`
/// value can be a unit struct, a `&'static`, or the component's own.
pub trait Crypto {
    fn verify_ed25519(&self, public_key_hex: &str, message: &[u8], signature_hex: &str) -> bool;
}

/// The signature side, implemented by the node's identity (and by this crate's own test key). The
/// guest never implements it: no key crosses into a component.
pub trait Signer {
    fn node_id(&self) -> &str;
    fn public_key(&self) -> &str;
    fn sign(&self, message: &str) -> String;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_node_id_is_the_hash_of_the_public_key() {
        // A 64-hex public key, so the id derivation is exercised on real shapes.
        let key = "a".repeat(64);
        let id = derive_node_id(&key).unwrap();
        assert_eq!(id.len(), 32);
        assert_eq!(id, sha256_bytes_hex(&unhex(&key).unwrap())[..32].to_string());
        assert!(derive_node_id("not hex").is_none());
        assert!(derive_node_id("abc").is_none());
        assert_eq!(unhex(&hex(b"wa")), Some(b"wa".to_vec()));
        assert_eq!(sha256_hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    }
}
