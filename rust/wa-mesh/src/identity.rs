//! The node's identity, as the mesh uses it.
//!
//! Same key file, same pkcs8-hex format, same `node_id` derivation (`sha256(public_key)[..32]`) as
//! `rust/wa-rendezvous/src/node.rs`: there is exactly one identity per node and the mesh must not
//! grow a second one. It is loaded here rather than through `wa_rendezvous::node::Identity::load`
//! because that one resolves its path from the process environment only — and a test with three
//! nodes in one process cannot change the environment per node. Loading from an explicit path is
//! the whole difference; the bytes on disk are identical.
use ring::rand::SystemRandom;
use ring::signature::{Ed25519KeyPair, KeyPair, UnparsedPublicKey, ED25519};
use std::path::{Path, PathBuf};

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

/// The key file this process uses when nothing says otherwise: `WASM_AGENT_NODE_KEY`, else
/// `<home>/.wasm-agent/node.key` — the same order the rendezvous client and `/node/call` use.
pub fn default_key_path() -> PathBuf {
    if let Ok(path) = std::env::var("WASM_AGENT_NODE_KEY") {
        if !path.is_empty() {
            return PathBuf::from(path);
        }
    }
    PathBuf::from(wa_host_support::paths::resolve_home())
        .join(".wasm-agent")
        .join("node.key")
}

pub struct Identity {
    pub node_id: String,
    pub public_key: String,
    key: Ed25519KeyPair,
}

impl std::fmt::Debug for Identity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Identity")
            .field("node_id", &self.node_id)
            .field("public_key", &self.public_key)
            .finish_non_exhaustive()
    }
}

impl Identity {
    /// Load the key at `path`, generating it on first use (0600, owner only). A key that cannot be
    /// read as pkcs8 is an error, never a fresh identity: silently minting a new key would make a
    /// node answer to a different `node_id` without anyone being told.
    pub fn load(path: &Path) -> Result<Identity, String> {
        let pkcs8 = match std::fs::read_to_string(path) {
            Ok(text) => unhex(&text).ok_or_else(|| "bad_node_key".to_string())?,
            Err(_) => {
                let rng = SystemRandom::new();
                let document =
                    Ed25519KeyPair::generate_pkcs8(&rng).map_err(|error| error.to_string())?;
                let bytes = document.as_ref().to_vec();
                if let Some(parent) = path.parent() {
                    wa_host_support::paths::private_dir(parent);
                }
                let mut options = std::fs::OpenOptions::new();
                options.write(true).create_new(true);
                #[cfg(unix)]
                {
                    use std::os::unix::fs::OpenOptionsExt;
                    options.mode(0o600);
                }
                use std::io::Write;
                options
                    .open(path)
                    .and_then(|mut file| file.write_all(hex(&bytes).as_bytes()))
                    .map_err(|error| error.to_string())?;
                bytes
            }
        };
        Identity::from_pkcs8_hex(&hex(&pkcs8))
    }

    pub fn from_pkcs8_hex(text: &str) -> Result<Identity, String> {
        let pkcs8 = unhex(text).ok_or_else(|| "bad_node_key".to_string())?;
        let key = Ed25519KeyPair::from_pkcs8(&pkcs8).map_err(|error| error.to_string())?;
        let public_key = hex(key.public_key().as_ref());
        let node_id = derive_node_id(&public_key).ok_or_else(|| "bad_public_key".to_string())?;
        Ok(Identity { node_id, public_key, key })
    }

    pub fn sign(&self, message: &str) -> String {
        hex(self.key.sign(message.as_bytes()).as_ref())
    }
}

/// The node id a public key answers to: the first 32 hex characters of `sha256(public_key)`.
///
/// This is why a roster entry can be checked at all: an entry that claims a `node_id` its
/// `public_key` does not hash to is a typo or an attack, and either way it is refused.
pub fn derive_node_id(public_key_hex: &str) -> Option<String> {
    let public = unhex(public_key_hex)?;
    let digest = ring::digest::digest(&ring::digest::SHA256, &public);
    Some(hex(digest.as_ref())[..32].to_string())
}

pub fn verify(public_key_hex: &str, message: &str, signature_hex: &str) -> bool {
    let (Some(public), Some(signature)) = (unhex(public_key_hex), unhex(signature_hex)) else {
        return false;
    };
    UnparsedPublicKey::new(&ED25519, public)
        .verify(message.as_bytes(), &signature)
        .is_ok()
}

/// SHA-256 of a body, as hex. The mesh signs the hash of the bytes it sends, so what was signed is
/// what was asked for and not merely that something was.
pub fn sha256_hex(text: &str) -> String {
    hex(ring::digest::digest(&ring::digest::SHA256, text.as_bytes()).as_ref())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_key_round_trips_and_signs_what_it_says() {
        let dir = std::env::temp_dir().join(format!("wa-mesh-identity-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("node.key");
        let _ = std::fs::remove_file(&path);
        let identity = Identity::load(&path).unwrap();
        let reloaded = Identity::load(&path).unwrap();
        assert_eq!(identity.node_id, reloaded.node_id);
        assert_eq!(identity.public_key, reloaded.public_key);
        assert_eq!(identity.node_id.len(), NODE_ID_TEST_LEN);
        let signature = identity.sign("mesh-call-v1|x|1|y");
        assert!(verify(&identity.public_key, "mesh-call-v1|x|1|y", &signature));
        assert!(!verify(&identity.public_key, "mesh-call-v1|x|1|z", &signature));
        assert_eq!(derive_node_id(&identity.public_key).unwrap(), identity.node_id);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_missing_key_is_not_a_new_identity_when_the_file_is_unreadable() {
        let dir = std::env::temp_dir().join(format!("wa-mesh-identity-bad-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("bad.key");
        std::fs::write(&path, "not-hex").unwrap();
        assert_eq!(Identity::load(&path).unwrap_err(), "bad_node_key");
        let _ = std::fs::remove_dir_all(&dir);
    }

    const NODE_ID_TEST_LEN: usize = 32;
}
