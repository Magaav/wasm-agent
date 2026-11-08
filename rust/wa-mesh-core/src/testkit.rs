//! Test keys and node fixtures, for this crate's own tests only.
//!
//! The signature side here is a plain ed25519 key derived from a name, so a test can rebuild the same
//! fleet on any machine. It is the *same* crate the `wa:mesh` guest uses, which is the point: the tests
//! in this file exercise the verifier the component ships, and the node's tests (`wa-mesh`) exercise
//! the ring one. Two implementations, one specification, and both are asserted against the same
//! canonical bytes.
use crate::crypto::{derive_node_id, hex, sha256_bytes_hex, unhex, Crypto, Signer};
use crate::roster::RosterNode;
use ed25519_dalek::{Signature, SigningKey, Verifier, VerifyingKey};

/// A key pair a test can rebuild from a name.
pub struct TestKey {
    signing: SigningKey,
    pub public_key: String,
    pub node_id: String,
}

impl TestKey {
    pub fn named(name: &str) -> TestKey {
        let seed = sha256_bytes_hex(name.as_bytes());
        let mut bytes = [0u8; 32];
        bytes.copy_from_slice(&unhex(&seed).unwrap());
        let signing = SigningKey::from_bytes(&bytes);
        let public_key = hex(signing.verifying_key().as_bytes());
        let node_id = derive_node_id(&public_key).expect("a derived id");
        TestKey { signing, public_key, node_id }
    }
}

impl Signer for TestKey {
    fn node_id(&self) -> &str {
        &self.node_id
    }

    fn public_key(&self) -> &str {
        &self.public_key
    }

    fn sign(&self, message: &str) -> String {
        use ed25519_dalek::Signer as _;
        hex(self.signing.sign(message.as_bytes()).to_bytes().as_ref())
    }
}

/// The verifier the guest ships, in the shape this crate's tests need.
pub struct TestCrypto;

impl Crypto for TestCrypto {
    fn verify_ed25519(&self, public_key_hex: &str, message: &[u8], signature_hex: &str) -> bool {
        let (Some(public), Some(signature)) = (unhex(public_key_hex), unhex(signature_hex)) else {
            return false;
        };
        let (Ok(public), Ok(signature)) = (
            VerifyingKey::from_bytes(&public[..].try_into().unwrap_or([0u8; 32])),
            Signature::from_slice(&signature),
        ) else {
            return false;
        };
        public.verify(message, &signature).is_ok()
    }
}

pub fn crypto() -> TestCrypto {
    TestCrypto
}

pub fn fleet_key() -> TestKey {
    TestKey::named("fleet-key")
}

/// A roster node with a key derived from its name and no revocation.
pub fn node(name: &str, level: u8, addresses: &[&str]) -> RosterNode {
    let key = TestKey::named(name);
    RosterNode {
        node_id: key.node_id.clone(),
        public_key: key.public_key.clone(),
        name: name.to_string(),
        level,
        addresses: addresses.iter().map(|address| address.to_string()).collect(),
        revoked_at: 0,
    }
}
