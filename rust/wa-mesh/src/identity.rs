//! The node's identity, as the mesh uses it.
//!
//! Same key file, same pkcs8-hex format, same `node_id` derivation (`sha256(public_key)[..32]`) as
//! `rust/wa-rendezvous/src/node.rs`: there is exactly one identity per node and the mesh must not
//! grow a second one. It is loaded here rather than through `wa_rendezvous::node::Identity::load`
//! because that one resolves its path from the process environment only — and a test with three
//! nodes in one process cannot change the environment per node. Loading from an explicit path is
//! the whole difference; the bytes on disk are identical.
//!
//! **The two halves live in two places.** The *hash* and the *verifier* are
//! `wa-mesh-core::crypto`'s, because the roster, the node id and the attestation must be the same bytes
//! in the guest. The *key* (signing, loading, generating) is this file's, because a key is the node's and
//! never a component's. [`RingCrypto`] is the build input the core asks for: ring's ed25519, which is
//! what signed every roster this node has ever seen.
use ring::rand::SystemRandom;
use ring::signature::{Ed25519KeyPair, KeyPair, UnparsedPublicKey, ED25519};
use std::path::{Path, PathBuf};

pub use wa_mesh_core::crypto::{derive_node_id, hex, sha256_bytes_hex, sha256_hex, unhex, Crypto, Signer};
use crate::roster::RosterSigner;

/// The verifier this build supplies to the mesh's logic. Stateless: a verifier holds no key.
#[derive(Debug, Default, Clone, Copy)]
pub struct RingCrypto;

impl Crypto for RingCrypto {
    fn verify_ed25519(&self, public_key_hex: &str, message: &[u8], signature_hex: &str) -> bool {
        let (Some(public), Some(signature)) = (unhex(public_key_hex), unhex(signature_hex)) else {
            return false;
        };
        UnparsedPublicKey::new(&ED25519, public)
            .verify(message, &signature)
            .is_ok()
    }
}

/// The one verifier a node has, for the call sites that do not want to name it.
pub fn crypto() -> &'static dyn Crypto {
    static RING: RingCrypto = RingCrypto;
    &RING
}

/// `verify(pk, message, signature)` in the shape the rest of the crate already called it.
pub fn verify(public_key_hex: &str, message: &str, signature_hex: &str) -> bool {
    crypto().verify_ed25519(public_key_hex, message.as_bytes(), signature_hex)
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

impl Signer for Identity {
    fn node_id(&self) -> &str {
        &self.node_id
    }

    fn public_key(&self) -> &str {
        &self.public_key
    }

    fn sign(&self, message: &str) -> String {
        Identity::sign(self, message)
    }
}

/// The operator's fleet key may be this node key file (`wa fleet sign --key <path>`), and `fleetkey`
/// takes any [`RosterSigner`]: this is the implementation that says a node key and a fleet key are the
/// same ed25519 machinery, loaded through the same `Identity`. The vault's implementation is
/// `fleetchange::VaultSigner`, where the seed never leaves the engine.
impl RosterSigner for Identity {
    fn public_key(&self) -> String {
        self.public_key.clone()
    }

    fn sign_message(&mut self, message: &str) -> Result<String, String> {
        Ok(Identity::sign(self, message))
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

    /// Load a key the caller named. Unlike [`Identity::load`], a missing file is an error and never a
    /// fresh identity: `wa fleet sign` must fail when the operator's fleet key is not where they said
    /// it was, because silently minting one would sign a roster with a key nobody pinned.
    pub fn open(path: &Path) -> Result<Identity, String> {
        match std::fs::read_to_string(path) {
            Ok(text) => {
                let text = text.trim();
                if text.is_empty() {
                    return Err("node_key_empty".to_string());
                }
                Identity::from_pkcs8_hex(text)
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                Err("node_key_missing".to_string())
            }
            Err(error) => Err(error.to_string()),
        }
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

/// A fresh key pair as pkcs8 hex, with the identity that answers to it. Nothing is written here:
/// `wa fleet keygen` owns the one place a private key may go (one explicit path, nothing else).
///
/// The fleet key is the same ed25519 machinery as the node identity on purpose — there is no second
/// kind of key to protect, rotate or lose (docs/MESH.md §1, "Who signs").
#[allow(clippy::type_complexity)]
pub fn generate() -> Result<(String, Identity), String> {
    let rng = SystemRandom::new();
    let document = Ed25519KeyPair::generate_pkcs8(&rng).map_err(|error| error.to_string())?;
    let bytes = document.as_ref().to_vec();
    let text = hex(&bytes);
    let identity = Identity::from_pkcs8_hex(&text)?;
    Ok((text, identity))
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
        // The trait and the inherent method are one signature, not two.
        assert_eq!(Signer::sign(&identity, "a"), identity.sign("a"));
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

    #[test]
    fn ring_and_the_mesh_core_agree_on_a_signature() {
        // The node verifies with ring, the guest with dalek; a signature is either valid or it is not.
        let (_text, identity) = generate().unwrap();
        let signature = identity.sign("mesh-roster-v1|fleet|1|0|{}");
        assert!(crypto().verify_ed25519(&identity.public_key, b"mesh-roster-v1|fleet|1|0|{}", &signature));
        assert!(!crypto().verify_ed25519(&identity.public_key, b"mesh-roster-v1|fleet|1|0|{ }", &signature));
    }

    const NODE_ID_TEST_LEN: usize = 32;
}
