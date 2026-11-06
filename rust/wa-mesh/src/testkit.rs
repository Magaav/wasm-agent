//! Test scaffolding shared by this crate's tests: throwaway identities, rosters and temp dirs.
//!
//! Every identity here is generated in the system temp directory, never in a node home, and every
//! listener binds `127.0.0.1:0`, so a test can never meet the real fabric and never takes a port a
//! running node uses (the job's hard rule: no 8799/8800/8890, no `~/.wasm-agent`).
#![cfg(test)]

use crate::identity::Identity;
use crate::roster::{Draft, Roster, RosterNode};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

static COUNTER: AtomicU64 = AtomicU64::new(0);

pub fn temp_dir(tag: &str) -> PathBuf {
    let count = COUNTER.fetch_add(1, Ordering::Relaxed);
    let directory = std::env::temp_dir().join(format!(
        "wa-mesh-test-{}-{}-{}",
        std::process::id(),
        count,
        tag
    ));
    let _ = std::fs::remove_dir_all(&directory);
    std::fs::create_dir_all(&directory).expect("temp dir");
    directory
}

pub fn identity(tag: &str) -> Identity {
    Identity::load(&temp_dir(tag).join("node.key")).expect("identity")
}

pub fn fleet_key() -> Identity {
    identity("fleet")
}

/// One test node: its key file, the identity loaded from it, and the roster entry it answers to.
///
/// `Identity` owns a key pair and is not `Clone`, which is exactly right for a node — so a test that
/// needs the node twice (a server and a client) reloads the same key file, which is the same identity
/// and not a second one.
pub struct Member {
    pub key_path: PathBuf,
    pub identity: Identity,
    pub node: RosterNode,
}

impl Member {
    pub fn new(name: &str, level: u8, addresses: &[&str]) -> Member {
        let key_path = temp_dir(name).join("node.key");
        let identity = Identity::load(&key_path).expect("identity");
        let node = RosterNode {
            node_id: identity.node_id.clone(),
            public_key: identity.public_key.clone(),
            name: name.to_string(),
            level,
            addresses: addresses.iter().map(|address| address.to_string()).collect(),
            revoked_at: 0,
        };
        Member { key_path, identity, node }
    }

    pub fn reload(&self) -> Identity {
        Identity::load(&self.key_path).expect("identity reload")
    }
}

pub fn node_with(name: &str, level: u8, addresses: &[&str], revoked_at: u64) -> RosterNode {
    let mut entry = Member::new(name, level, addresses).node;
    entry.revoked_at = revoked_at;
    entry
}

pub fn node(name: &str, level: u8, addresses: &[&str]) -> RosterNode {
    node_with(name, level, addresses, 0)
}

pub fn roster_of(fleet_key: &Identity, nodes: Vec<RosterNode>) -> Roster {
    Draft {
        fleet: "ohana".into(),
        issued_at: crate::wire::now_seconds().saturating_sub(60),
        expires_at: 0,
        nodes,
    }
    .sign(fleet_key)
}

/// A roster that was signed and then edited: the signature is real, the document is not the one that
/// was signed. Every receiver must refuse it (`roster_unverified:bad_signature`).
pub fn tampered(roster: Roster, fleet_key: &Identity) -> Roster {
    let mut edited = roster.clone();
    edited.nodes[0].level = 9;
    let mut signed = edited.clone();
    signed.sign(fleet_key);
    // Now change it after signing, which is what an attacker with file access would do.
    let mut tampered = signed;
    tampered.nodes[0].level = 0;
    tampered
}

/// One lock for the tests that have to set process environment variables (the flag and the paths).
/// `std::env` is process-global, so a test that changes it has to exclude the others or the suite
/// becomes order-dependent — which is exactly the kind of flake that makes a green run meaningless.
pub static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

pub struct EnvGuard {
    saved: Vec<(String, Option<String>)>,
}

impl EnvGuard {
    /// Set variables for the duration of a test and restore them afterwards, even on a panic.
    pub fn set(pairs: &[(&str, Option<&str>)]) -> EnvGuard {
        let mut saved = Vec::new();
        for (name, value) in pairs {
            saved.push(((*name).to_string(), std::env::var(name).ok()));
            match value {
                Some(value) => std::env::set_var(name, value),
                None => std::env::remove_var(name),
            }
        }
        EnvGuard { saved }
    }
}

impl Drop for EnvGuard {
    fn drop(&mut self) {
        for (name, value) in self.saved.drain(..) {
            match value {
                Some(value) => std::env::set_var(&name, value),
                None => std::env::remove_var(&name),
            }
        }
    }
}

/// A port that was free a moment ago. Binding `127.0.0.1:0`, reading the port and dropping it is the
/// usual trick; the window between the drop and the real bind is the reason a port, not a guarantee,
/// is what `spawn_from_env` documents.
pub fn free_port() -> u16 {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("probe bind");
    listener.local_addr().expect("probe address").port()
}
