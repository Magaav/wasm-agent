//! Test scaffolding: a self-signed HTTPS server on loopback, and a guard that installs the anchors a
//! test means without touching the process environment.
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

use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, RwLock};
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

/// What the server does once the TLS handshake and the request head are read.
#[derive(Clone, Copy)]
enum Answer {
    /// HTTP/1.1 200 OK with the body ok.
    Http,
    /// The RFC 6455 upgrade, then every frame echoed back with its own opcode.
    Echo,
}

impl Server {
    /// A server whose certificate is signed by [`cert_file`].
    pub fn start() -> Server {
        Server::start_with("server.pem", "server.key", Answer::Http)
    }

    /// A plain-HTTP server on the same loopback pattern: the destination of the request that must keep
    /// working when the machine's CA bundle cannot be read (no handshake, so no anchors).
    pub fn start_plain() -> Server {
        Server::plain(false)
    }

    /// A plain ws:// websocket server: the same upgrade and echo, without TLS. It is what proves a
    /// broken CA bundle does not refuse a plain websocket upgrade (review r1, item 7).
    pub fn start_plain_websocket() -> Server {
        Server::plain(true)
    }

    /// A server whose certificate is signed by [`other_cert_file`].
    pub fn start_other() -> Server {
        Server::start_with("other-server.pem", "other-server.key", Answer::Http)
    }

    /// A websocket server on the same certificate: a real upgrade (a correct Sec-WebSocket-Accept),
    /// then every frame echoed back. A client that only reached the TLS handshake cannot pass a test
    /// that uses this, which is the point of it.
    pub fn start_websocket() -> Server {
        Server::start_with("server.pem", "server.key", Answer::Echo)
    }

    fn plain(websocket: bool) -> Server {
        let listener = TcpListener::bind("127.0.0.1:0").expect("a loopback port for the scratch server");
        listener.set_nonblocking(true).expect("a non-blocking listener");
        let port = listener.local_addr().expect("the scratch server's address").port();
        let stop = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&stop);
        let worker = std::thread::spawn(move || {
            while !flag.load(Ordering::SeqCst) {
                match listener.accept() {
                    Ok((stream, _)) => {
                        if websocket {
                            serve_plain_websocket(stream)
                        } else {
                            serve_plain(stream)
                        }
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(5))
                    }
                    Err(_) => break,
                }
            }
        });
        Server { base: format!("http://127.0.0.1:{port}"), stop, worker: Some(worker) }
    }

    fn start_with(certificate: &str, key: &str, answer: Answer) -> Server {
        let config = Arc::new(server_config(certificate, key));
        let listener = TcpListener::bind("127.0.0.1:0").expect("a loopback port for the scratch server");
        listener.set_nonblocking(true).expect("a non-blocking listener");
        let port = listener.local_addr().expect("the scratch server's address").port();
        let stop = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&stop);
        let worker = std::thread::spawn(move || {
            while !flag.load(Ordering::SeqCst) {
                match listener.accept() {
                    Ok((stream, _)) => serve(stream, &config, answer),
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
        let (scheme, rest) = match self.base.split_once("://") {
            Some((scheme, rest)) => (scheme, rest),
            None => ("http", self.base.as_str()),
        };
        let scheme = if scheme == "https" { "wss" } else { "ws" };
        format!("{scheme}://{rest}{path}")
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

/// The plain-HTTP sibling of serve: the same answer, without a handshake in front of it.
fn serve_plain(stream: std::net::TcpStream) {
    use std::io::Read as _;
    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(10)));
    let mut socket = stream;
    let mut head = Vec::new();
    let mut byte = [0u8; 1];
    while !head.windows(4).any(|window| window == b"\r\n\r\n") {
        match socket.read(&mut byte) {
            Ok(1) => head.push(byte[0]),
            _ => return,
        }
        if head.len() > 64 * 1024 {
            return;
        }
    }
    let _ = socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
    let _ = socket.flush();
}

/// The plain sibling of a websocket server: the same handshake and echo over a bare TCP stream.
fn serve_plain_websocket(stream: std::net::TcpStream) {
    use std::io::Read as _;
    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(10)));
    let mut socket = stream;
    let mut head = Vec::new();
    let mut byte = [0u8; 1];
    while !head.windows(4).any(|window| window == b"\r\n\r\n") {
        match socket.read(&mut byte) {
            Ok(1) => head.push(byte[0]),
            _ => return,
        }
        if head.len() > 64 * 1024 {
            return;
        }
    }
    serve_websocket(&mut socket, &head);
}

fn serve(stream: std::net::TcpStream, config: &Arc<ServerConfig>, answer: Answer) {
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
    if let Answer::Echo = answer {
        if header(&String::from_utf8_lossy(&head), "sec-websocket-key").is_some() {
            serve_websocket(&mut tls, &head);
            return;
        }
    }
    // Drain what the request announced before answering: a client still writing its body must not
    // meet a reset, which would look like a TLS failure and be reported as one.
    let text = String::from_utf8_lossy(&head).to_ascii_lowercase();
    if let Some(length) = content_length(&text) {
        drain(&mut tls, length);
    }
    let _ = tls.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
    let _ = tls.flush();
}

/// The RFC 6455 server side of the upgrade, then an echo of every frame until the client closes.
///
/// Written out rather than delegated to a websocket library: the test question is which TLS anchors
/// the CLIENT used, so the server job is to be a correct, boring peer - and a peer the test can read
/// is easier to trust than a second library defaults.
fn serve_websocket<IO: Read + Write>(tls: &mut IO, head: &[u8]) {
    let text = String::from_utf8_lossy(head).to_string();
    let Some(key) = header(&text, "sec-websocket-key") else {
        return;
    };
    let reply = format!(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {}\r\n\r\n",
        accept_key(key)
    );
    if tls.write_all(reply.as_bytes()).is_err() {
        return;
    }
    let _ = tls.flush();
    while let Some((opcode, payload)) = read_frame(tls) {
        if write_frame(tls, opcode, &payload).is_err() {
            return;
        }
        let _ = tls.flush();
        if opcode == 0x8 {
            return;
        }
    }
}

/// One header of a request head, case-insensitively, trimmed.
fn header<'a>(head: &'a str, name: &str) -> Option<&'a str> {
    head.lines().find_map(|line| {
        let (key, value) = line.split_once(':')?;
        key.trim().eq_ignore_ascii_case(name).then(|| value.trim())
    })
}

/// base64(sha1(key + the GUID RFC 6455 names)): the value a client checks before it will talk.
fn accept_key(key: &str) -> String {
    use base64::Engine;
    use sha1::{Digest, Sha1};
    let mut hasher = Sha1::new();
    hasher.update(key.trim().as_bytes());
    hasher.update(b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    base64::engine::general_purpose::STANDARD.encode(hasher.finalize())
}

/// One frame off the wire: its opcode and its unmasked payload.
fn read_frame<R: Read>(reader: &mut R) -> Option<(u8, Vec<u8>)> {
    let mut first = [0u8; 2];
    reader.read_exact(&mut first).ok()?;
    let opcode = first[0] & 0x0f;
    let masked = first[1] & 0x80 != 0;
    let mut length = u64::from(first[1] & 0x7f);
    if length == 126 {
        let mut extended = [0u8; 2];
        reader.read_exact(&mut extended).ok()?;
        length = u64::from(u16::from_be_bytes(extended));
    } else if length == 127 {
        let mut extended = [0u8; 8];
        reader.read_exact(&mut extended).ok()?;
        length = u64::from_be_bytes(extended);
    }
    // A test peer, not a server: anything past a megabyte is a client bug worth refusing.
    if length > 1024 * 1024 {
        return None;
    }
    let mut mask = [0u8; 4];
    if masked {
        reader.read_exact(&mut mask).ok()?;
    }
    let mut payload = vec![0u8; length as usize];
    reader.read_exact(&mut payload).ok()?;
    if masked {
        for (index, byte) in payload.iter_mut().enumerate() {
            *byte ^= mask[index % 4];
        }
    }
    Some((opcode, payload))
}

/// One frame onto the wire, unmasked: a server never masks.
fn write_frame<W: Write>(writer: &mut W, opcode: u8, payload: &[u8]) -> std::io::Result<()> {
    writer.write_all(&[0x80 | opcode])?;
    if payload.len() < 126 {
        writer.write_all(&[payload.len() as u8])?;
    } else {
        writer.write_all(&[126])?;
        writer.write_all(&(payload.len() as u16).to_be_bytes())?;
    }
    writer.write_all(payload)
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
/// The anchors for the length of one test, installed explicitly.
///
/// The first version of these tests set SSL_CERT_FILE with std::env::set_var. That is unsound in any
/// process with more than one thread - set_var mutates the environment other threads read through
/// getenv, and cargo runs one crate's tests in one process, in parallel (review r1, item 4). So the
/// seam is not the environment: a test installs the anchors it means, wa_tls answers from them while
/// the guard is held, and no process-wide state another thread can observe is written.
pub struct Env {
    _guard: MutexGuard<'static, ()>,
    previous: Option<(Option<String>, Option<String>)>,
}

impl Env {
    /// Both variables absent first, then exactly the pairs given.
    pub fn set(values: &[(&'static str, &Path)]) -> Env {
        let mut file = None;
        let mut dirs = None;
        for (name, path) in values {
            let text = Some(path.to_string_lossy().into_owned());
            match *name {
                CERT_FILE => file = text,
                CERT_DIR => dirs = text,
                other => panic!("{other} is not one of the two CA variables"),
            }
        }
        Env::install(Some((file, dirs)))
    }

    /// Both variables absent: the machine that names no bundle.
    pub fn clear() -> Env {
        Env::install(Some((None, None)))
    }

    /// One variable set to a value that is not a path at all - the misconfiguration the loader must
    /// name instead of excusing.
    pub fn set_text(name: &'static str, value: &str) -> Env {
        let text = Some(value.to_string());
        match name {
            CERT_FILE => Env::install(Some((text, None))),
            CERT_DIR => Env::install(Some((None, text))),
            other => panic!("{other} is not one of the two CA variables"),
        }
    }

    fn install(value: Option<(Option<String>, Option<String>)>) -> Env {
        let guard = lock();
        let previous = installed_override();
        *state().write().unwrap_or_else(|poisoned| poisoned.into_inner()) = value;
        Env { _guard: guard, previous }
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        *state().write().unwrap_or_else(|poisoned| poisoned.into_inner()) = self.previous.take();
    }
}

/// The anchors a test installed, if any: read by wa_tls::tls_config and wa_tls::anchors before they
/// look at the environment.
pub(crate) fn installed_override() -> Option<(Option<String>, Option<String>)> {
    state()
        .read()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .clone()
}

fn state() -> &'static RwLock<Option<(Option<String>, Option<String>)>> {
    static STATE: OnceLock<RwLock<Option<(Option<String>, Option<String>)>>> = OnceLock::new();
    STATE.get_or_init(|| RwLock::new(None))
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
