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

/// The deadline on one read or write in a test.
///
/// A loopback socket in a test still gets a bound: 30 s is generous enough that a machine which is
/// busy (measured: loopback round trips at ~300 ms under a full core load, and individual handshakes
/// stalling for seconds) does not fail a correct test, and small enough that a peer which never
/// answers fails the test rather than the deadline below.
pub const SOCKET_DEADLINE: std::time::Duration = std::time::Duration::from_secs(30);

/// The connect budget the test doubles use.
///
/// Two seconds was enough on an idle machine and not enough on a busy one: a loopback handshake was
/// measured taking over two seconds while `cargo test --workspace` compiled wasmtime on all cores, and
/// the test failed with `connect_failed:connection timed out` instead of testing anything. The socket
/// op still has a deadline — a generous one — and the per-test deadline above is the real backstop.
pub const CONNECT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(15);

/// The hard per-test deadline. Every end-to-end test here runs under it.
///
/// The slowest real step is a connect that is deliberately going nowhere (`127.0.0.1:1`, which on a
/// loaded Windows box waits out the whole connect budget), so a whole test needs seconds, not
/// minutes. Two minutes is far above the worst measured run (a few seconds, and ~20 s for the whole
/// binary under a full workspace build) and far below the twenty-minute stall a blocked `accept`
/// produced, so a regression fails the test by name instead of hanging the binary.
pub const TEST_DEADLINE: std::time::Duration = std::time::Duration::from_secs(120);

/// Run one test body under a hard deadline, on its own thread.
///
/// A test that overruns fails with the test's name and the fact that it hung; it never leaves libtest
/// waiting on a blocked socket with the binary at zero CPU. A body that panics keeps its original
/// payload and location (`resume_unwind`, so the message is not printed twice).
pub fn with_deadline<F>(name: &str, body: F)
where
    F: FnOnce() + Send + 'static,
{
    with_deadline_for(name, TEST_DEADLINE, body)
}

/// [`with_deadline`] with an explicit budget, so the guard itself can be tested without waiting a
/// minute for it.
pub fn with_deadline_for<F>(name: &str, deadline: std::time::Duration, body: F)
where
    F: FnOnce() + Send + 'static,
{
    let (done, wait) = std::sync::mpsc::channel();
    let worker = std::thread::Builder::new()
        .name(format!("test:{name}"))
        .spawn(move || {
            body();
            // Send *after* the body returns, so the harness cannot see a pass before its work ends.
            let _ = done.send(());
        })
        .expect("test thread");
    match wait.recv_timeout(deadline) {
        Ok(()) => {
            if let Err(payload) = worker.join() {
                std::panic::resume_unwind(payload);
            }
        }
        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => panic!(
            "{name} did not finish in {}s: something in it is blocked (a socket op without a \
             deadline, or a join on a thread that never stops)",
            deadline.as_secs()
        ),
        // The worker died without sending: it panicked, most likely while holding a lock. Join to
        // keep the assertion message and the original location, and let the harness report it.
        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => match worker.join() {
            Ok(()) => panic!("{name} ended without reaching the end of its body"),
            Err(payload) => std::panic::resume_unwind(payload),
        },
    }
}

/// A listener that is cheap to stop: non-blocking accept, a stop flag checked every poll.
///
/// The test doubles (a rendezvous) were woken out of a blocking `accept` by a throwaway connect from
/// `Drop`. A connect that fails — which a loaded machine can produce on loopback — left the thread in
/// `accept` and `Drop` in `join` forever. Polling removes the socket op from the shutdown path.
pub const ACCEPT_POLL: std::time::Duration = std::time::Duration::from_millis(5);
