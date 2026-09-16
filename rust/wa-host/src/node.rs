//! Node identity: an ed25519 keypair that survives restarts.
//!
//! Nodes are bound by **key**, never by address, so rotating IPs and NAT do not
//! matter: a node re-announces on reconnect and is recognised by `node_id`.
use ring::rand::SystemRandom;
use ring::signature::{Ed25519KeyPair, KeyPair, UnparsedPublicKey, ED25519};
use serde_json::json;
use std::path::PathBuf;
use std::time::Duration;

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

pub fn unhex(text: &str) -> Option<Vec<u8>> {
    let text = text.trim();
    if text.len() % 2 != 0 {
        return None;
    }
    (0..text.len() / 2)
        .map(|index| u8::from_str_radix(&text[index * 2..index * 2 + 2], 16).ok())
        .collect()
}

fn home() -> String {
    std::env::var("HOME").unwrap_or_else(|_| ".".into())
}

fn key_path() -> PathBuf {
    if let Ok(path) = std::env::var("WASM_AGENT_NODE_KEY") {
        if !path.is_empty() {
            return PathBuf::from(path);
        }
    }
    PathBuf::from(home()).join(".wasm-agent").join("node.key")
}

pub struct Identity {
    pub node_id: String,
    pub public_key: String,
    key: Ed25519KeyPair,
}

impl Identity {
    pub fn load() -> Result<Identity, String> {
        let path = key_path();
        let pkcs8 = match std::fs::read_to_string(&path) {
            Ok(text) => unhex(&text).ok_or("bad_node_key")?,
            Err(_) => {
                let rng = SystemRandom::new();
                let document =
                    Ed25519KeyPair::generate_pkcs8(&rng).map_err(|error| error.to_string())?;
                let bytes = document.as_ref().to_vec();
                if let Some(parent) = path.parent() {
                    let _ = std::fs::create_dir_all(parent);
                }
                std::fs::write(&path, hex(&bytes)).map_err(|error| error.to_string())?;
                bytes
            }
        };
        let key = Ed25519KeyPair::from_pkcs8(&pkcs8).map_err(|error| error.to_string())?;
        let public_key = hex(key.public_key().as_ref());
        let digest = ring::digest::digest(&ring::digest::SHA256, key.public_key().as_ref());
        let node_id = hex(digest.as_ref())[..32].to_string();
        Ok(Identity { node_id, public_key, key })
    }

    pub fn sign(&self, message: &str) -> String {
        hex(self.key.sign(message.as_bytes()).as_ref())
    }
}

pub fn verify(public_key_hex: &str, message: &str, signature_hex: &str) -> bool {
    let (Some(public), Some(signature)) = (unhex(public_key_hex), unhex(signature_hex)) else {
        return false;
    };
    UnparsedPublicKey::new(&ED25519, public)
        .verify(message.as_bytes(), &signature)
        .is_ok()
}

/// The canonical string a node signs when announcing itself.
pub fn announcement(node_id: &str, ts: u64) -> String {
    format!("{node_id}|{ts}")
}

/// Register once and then heartbeat, in the background. Outbound only, so no
/// inbound port or NAT traversal is required.
pub fn spawn_heartbeat(url: String) {
    std::thread::spawn(move || {
        let identity = match Identity::load() {
            Ok(identity) => identity,
            Err(error) => {
                eprintln!("[rendezvous] identity unavailable: {error}");
                return;
            }
        };
        let endpoint = std::env::var("WASM_AGENT_ENDPOINT").unwrap_or_default();
        let name = std::env::var("WASM_AGENT_NODE_NAME")
            .unwrap_or_else(|_| identity.node_id[..8].to_string());
        let role = std::env::var("WASM_AGENT_NODE_ROLE").unwrap_or_else(|_| "master".into());
        let mut registered = false;
        loop {
            let ts = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|duration| duration.as_secs())
                .unwrap_or(0);
            let message = announcement(&identity.node_id, ts);
            let payload = json!({
                "node_id": identity.node_id,
                "public_key": identity.public_key,
                "name": name,
                "role": role,
                "endpoints": if endpoint.is_empty() { vec![] } else { vec![endpoint.clone()] },
                "ts": ts,
                "signature": identity.sign(&message),
            })
            .to_string();
            let path = if registered { "heartbeat" } else { "register" };
            let target = format!("{}/{}", url.trim_end_matches('/'), path);
            let agent: ureq::Agent = ureq::Agent::config_builder()
                .http_status_as_error(false)
                .build()
                .into();
            match agent
                .post(&target)
                .header("Content-Type", "application/json")
                .send(payload.as_bytes())
            {
                Ok(response) if response.status().as_u16() == 200 => {
                    if !registered {
                        eprintln!("[rendezvous] registered {} at {url}", &identity.node_id[..8]);
                        registered = true;
                    }
                }
                Ok(response) => eprintln!("[rendezvous] {path} -> {}", response.status().as_u16()),
                Err(error) => eprintln!("[rendezvous] {path} failed: {error}"),
            }
            std::thread::sleep(Duration::from_secs(60));
        }
    });
}
