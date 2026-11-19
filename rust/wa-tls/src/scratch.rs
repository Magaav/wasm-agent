//! Test scaffolding: a self-signed HTTPS server on loopback, and a guard for the two variables.
//!
//! Why a server and not a mock: the question these tests ask is what the TLS handshake accepts, and a
//! mock connector would answer for a client nobody ships. The server here is the same rustls that
//! ureq verifies with, presenting the certificate in `fixtures/scratch-tls` (generated once by
//! `fixtures/scratch-tls/generate.sh`, valid until 2126), so a request either completes a real
//! handshake against a private CA or fails at the one step the change touches.
//!
//! Nothing here touches the agent's own state: no home directory, no ledger, no port outside
//! `127.0.0.1`. A test that uses it binds an ephemeral loopback port and, when it needs a bundle on
//! disk, writes under the system temp directory in a directory of its own.

use std::ffi::OsString;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::thread::JoinHandle;
use std::time::Duration;

use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use rustls::{ServerConfig, ServerConnection, StreamOwned};
use ureq::tls::PemItem;

use super::{CERT_DIR, CERT_FILE};

/// The committed TLS material, addressed from the crate that owns it rather than from the caller's
/// working directory: a test that runs from another directory still finds its own fixture.
pub fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("fixtures").join("scratch-tls")
}

/// A file of the fixture set by name.
pub fn fixture(name: &str) -> PathBuf {
    fixtures().join(name)
}

/// The PEM bundle that signs [`Server::start`]'s certificate.
pub fn cert_file() -> PathBuf {
    fixture("ca.pem")
}

/// The second, unrelated CA: the one that proves a union rather than a replacement.
pub fn other_cert_file() -> PathBuf {
    fixture("otherca.pem")
}

/// An HTTPS server on an ephemeral loopback port, answering every request with `ok`.
pub struct Server {
    base: String,
    stop: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
}

impl Server {
    /// A server whose certificate is signed by [`cert_file`].
    pub fn start() -> Server {
        Server::start_with("server.pem", "server.key")
    }

    /// A server whose certificate is signed by [`other_cert_file`].
    pub fn start_other() -> Server {
        Server::start_with("other-server.pem", "other-server.key")
    }

    fn start_with(certificate: &str, key: &str) -> Server {
        let config = Arc::new(server_config(certificate, key));
        let listener = TcpListener::bind("127.0.0.1:0").expect("a loopback port for the scratch server");
        listener.set_nonblocking(true).expect("a non-blocking listener");
        let port = listener.local_addr().expect("the scratch server's address").port();
        let stop = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&stop);
        let worker = std::thread::spawn(move || {
            while !flag.load(Ordering::SeqCst) {
                match listener.accept() {
                    Ok((stream, _)) => serve(stream, &config),
                    // Nothing waiting: sleep a moment rather than spin, and re-check the flag.
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(5))
                    }
                    Err(_) => break,
                }
            }
        });
        Server {
            base: format!("https://127.0.0.1:{port}"),
            stop,
            worker: Some(worker),
        }
    }

    /// The base URL, without a path.
    pub fn base(&self) -> &str {
        &self.base
    }

    /// A URL on this server.
    pub fn url(&self, path: &str) -> String {
        format!("{}{path}", self.base)
    }

    /// The same server as a websocket URL: a websocket client parses only ws:// and wss://, and the
    /// handshake and the certificate are the same ones.
    pub fn ws_url(&self, path: &str) -> String {
        format!("wss://{}{path}", &self.base["https://".len()..])
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(worker) = self.worker.take() {
            // The accept loop wakes within its 5 ms sleep; a leaked thread would keep the port open
            // for the rest of the binary.
            let _ = worker.join();
        }
    }
}

fn server_config(certificate: &str, key: &str) -> ServerConfig {
    let chain_bytes = std::fs::read(fixture(certificate))
        .unwrap_or_else(|error| panic!("the fixture certificate {certificate}: {error}"));
    let mut chain: Vec<CertificateDer<'static>> = Vec::new();
    for item in ureq::tls::parse_pem(&chain_bytes) {
        if let Ok(PemItem::Certificate(cert)) = item {
            chain.push(CertificateDer::from(cert.der().to_vec()));
        }
    }
    assert!(!chain.is_empty(), "the fixture certificate {certificate} carries one");
    let key_bytes = std::fs::read(fixture(key))
        .unwrap_or_else(|error| panic!("the fixture key {key}: {error}"));
    let parsed = ureq::tls::parse_pem(&key_bytes)
        .find_map(|item| match item {
            Ok(PemItem::PrivateKey(key)) => Some(key),
            _ => None,
        })
        .unwrap_or_else(|| panic!("the fixture key {key} carries one"));
    // generate.sh writes an unencrypted PKCS#8 key ("BEGIN PRIVATE KEY"). Anything else means
    // the fixture came from another tool, and saying so beats a handshake that half works.
    assert!(
        key_bytes
            .windows(27)
            .any(|window| window == b"-----BEGIN PRIVATE KEY-----"),
        "the fixture key {key} must be unencrypted PKCS#8: regenerate it with generate.sh"
    );
    let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(parsed.der().to_vec()));
    ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(chain, key)
        .expect("a server config from the fixture material")
}

fn serve(stream: std::net::TcpStream, config: &Arc<ServerConfig>) {
    let _ = stream.set_nonblocking(false);
    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(10)));
    let Ok(connection) = ServerConnection::new(Arc::clone(config)) else {
        return;
    };
    let mut tls = StreamOwned::new(connection, stream);
    let Ok(head) = read_head(&mut tls) else {
        return;
    };
    // Drain what the request announced before answering: a client still writing its body must not
    // meet a reset, which would look like a TLS failure and be reported as one.
    let text = String::from_utf8_lossy(&head).to_ascii_lowercase();
    if let Some(length) = content_length(&text) {
        drain(&mut tls, length);
    }
    let _ = tls.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
    let _ = tls.flush();
}

fn read_head(tls: &mut StreamOwned<ServerConnection, std::net::TcpStream>) -> Result<Vec<u8>, ()> {
    let mut head = Vec::new();
    let mut byte = [0u8; 1];
    while !head.windows(4).any(|window| window == b"\r\n\r\n") {
        match tls.read(&mut byte) {
            Ok(1) => head.push(byte[0]),
            Ok(0) => break,
            Ok(_) => {}
            Err(_) => return Err(()),
        }
        if head.len() > 64 * 1024 {
            return Err(());
        }
    }
    Ok(head)
}

fn content_length(head: &str) -> Option<usize> {
    head.lines()
        .find_map(|line| line.strip_prefix("content-length:"))
        .and_then(|value| value.trim().parse().ok())
}

fn drain(tls: &mut StreamOwned<ServerConnection, std::net::TcpStream>, mut left: usize) {
    let mut chunk = [0u8; 4096];
    while left > 0 {
        let take = left.min(chunk.len());
        match tls.read(&mut chunk[..take]) {
            Ok(0) | Err(_) => return,
            Ok(read) => left -= read,
        }
    }
}

/// Holds the two CA variables still for the length of one test, then puts back what it found.
///
/// Process-wide by nature: the variables are read by the process, not by the test. The lock makes
/// two tests that change them run one after the other instead of reading each other's bundle - and a
/// test that does not take the lock never sees a half-applied set, because [`Env::set`] removes both
/// variables and installs the whole set before it returns.
pub struct Env {
    _guard: MutexGuard<'static, ()>,
    saved: Vec<(&'static str, Option<OsString>)>,
}

impl Env {
    /// Clear both variables, then install exactly the pairs given.
    pub fn set(values: &[(&'static str, &Path)]) -> Env {
        let guard = lock();
        let saved = vec![
            (CERT_FILE, std::env::var_os(CERT_FILE)),
            (CERT_DIR, std::env::var_os(CERT_DIR)),
        ];
        std::env::remove_var(CERT_FILE);
        std::env::remove_var(CERT_DIR);
        for (name, path) in values {
            std::env::set_var(name, path);
        }
        Env { _guard: guard, saved }
    }

    /// Both variables absent: the machine that names no bundle.
    pub fn clear() -> Env {
        Env::set(&[])
    }

    /// Also hold one more variable for the length of this guard, restored when it drops: the same
    /// lock, so a test that needs its own node key (or any other variable the code under test reads)
    /// cannot see another test's value.
    pub fn also(&mut self, name: &'static str, value: &Path) {
        self.saved.push((name, std::env::var_os(name)));
        std::env::set_var(name, value);
    }

    /// One variable set to a value that is not a path at all - the misconfiguration the loader must
    /// name instead of excusing.
    pub fn set_text(name: &'static str, value: &str) -> Env {
        let guard = lock();
        let saved = vec![
            (CERT_FILE, std::env::var_os(CERT_FILE)),
            (CERT_DIR, std::env::var_os(CERT_DIR)),
        ];
        std::env::remove_var(CERT_FILE);
        std::env::remove_var(CERT_DIR);
        std::env::set_var(name, value);
        Env { _guard: guard, saved }
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        for (name, value) in &self.saved {
            match value {
                Some(value) => std::env::set_var(name, value),
                None => std::env::remove_var(name),
            }
        }
    }
}

fn lock() -> MutexGuard<'static, ()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// A directory of the test's own under the system temp directory, removed when the test ends.
pub struct TempDir {
    path: PathBuf,
}

impl TempDir {
    pub fn new(label: &str) -> TempDir {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "wa-tls-{}-{}-{label}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::SeqCst)
        ));
        std::fs::create_dir_all(&path).expect("a scratch directory under the system temp directory");
        // Every file a test writes lives in this directory and goes when it does: no home
        // directory, no ledger, no port outside loopback. A runner that redirects TMPDIR somewhere
        // narrow (this one points it at the session's own scratch home) still gets a directory of
        // our own under it, and that is the only path this type ever writes.
        assert!(
            path.starts_with(std::env::temp_dir()),
            "a scratch directory must live under the temp dir: {}",
            path.display()
        );
        TempDir { path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Write a file of it and answer its path.
    pub fn write(&self, name: &str, bytes: &[u8]) -> PathBuf {
        let path = self.path.join(name);
        std::fs::write(&path, bytes).expect("a file in the test's own directory");
        path
    }

    /// Link the fixture certificate in under a name of the caller's choosing.
    pub fn copy_fixture(&self, fixture_name: &str, name: &str) -> PathBuf {
        let bytes = std::fs::read(fixture(fixture_name)).expect("a fixture file");
        self.write(name, &bytes)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}
