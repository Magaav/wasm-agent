//! `wa:kernel/vision` for service components: the node's native text reader (the RapidOCR worker the
//! WhatsApp connector provisions, `scripts/whatsapp-ocr-local.py --worker`) behind one warm worker.
//!
//! Why a kernel interface and not a provider component: the worker is the node's own Python
//! environment with an ONNX model (measured ~4.2 s for a 1000x260 fixture on two ARM cores,
//! `docs/WHATSAPP-OCR.md`), the same arrangement the kernel already has for speech. A wasi-nn
//! provider can replace this worker later without the guest's call changing (`wit/seams/seams.wit`
//! carries the provider shape; `wit/kernel-v2` carries the call).
//!
//! The lifecycle mirrors `service_stt` (the reason the two files read alike is that a node with two
//! different worker lifecycles is a node with two different bugs):
//!
//! * **One warm worker per host process, one image at a time.** A 2-core node cannot afford two
//!   model instances, and the OCR worker is bounded by its own 2-minute deadline.
//! * **Started on demand, or eagerly** (`prewarm`, called when a component holding the `ocr` grant
//!   starts) so the first screenshot does not pay the engine load.
//! * **A bounded queue.** At most [`QUEUE_DEPTH`] jobs wait; a further request is `busy`, which the
//!   guest answers as `again` and retries later. It never blocks the caller and never grows without
//!   limit - an image message burst must not be able to exhaust the kernel's memory.
//! * **Killed only when stuck or past its deadline**, then dropped so the next job starts a fresh
//!   worker ([`Hub::read`]); a job whose worker died is retried **once** on the new worker, and a
//!   second failure is reported, not retried forever.
//! * **Metadata only in logs.** The text belongs to the component's index and never to a log line;
//!   this module reports counts and milliseconds.
//!
//! Paths (references, never secrets): `WA_OCR_PYTHON` (default `~/.local/wa-ocr-rapid/bin/python`),
//! `WA_OCR_WORKER` (default `<runtime worktree>/scripts/whatsapp-ocr-local.py`, the worktree named
//! by `~/.local/bin/runtime-worktree.txt`). The recognizer's own model pair
//! (`WA_WHATSAPP_OCR_REC_MODEL`/`_KEYS`) is passed through untouched, so the worker's rule ("both
//! or neither, else `offline_model_unavailable`") stays the worker's.
//!
//! Never a log line: no caller may log `Reading::text`.

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, SyncSender, TrySendError};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

/// Largest image the kernel will hand the worker, the old bridge's own limit
/// (`scripts/whatsapp-ocr-local.py` refuses anything bigger with `image_too_large`). Checked here
/// as well so an oversized blob never reaches a temp file.
pub const MAX_IMAGE: usize = 20 << 20;
/// How long the worker may go without a line before it is treated as stuck.
const STALL: Duration = Duration::from_secs(120);
/// The whole job's deadline, the old bridge's 2-minute worker deadline. The worker itself is killed
/// at this point and the job fails `worker_timeout`.
const BUDGET: Duration = Duration::from_secs(120);
/// How many jobs may wait behind the one in flight. One image message burst is not a queue of
/// hundreds; a fifth caller is told to come back.
pub const QUEUE_DEPTH: usize = 4;

/// The text one read produced. `text` is content: it may be indexed, never logged.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Reading {
    pub text: String,
    /// The media type the caller named, echoed back.
    pub mime: String,
    /// Wall time the worker spent, milliseconds.
    pub elapsed_ms: u64,
}

/// Why a read did not produce text. The words are the worker's own (`docs/WHATSAPP-OCR.md`), so a
/// component can decide what is worth retrying without reading the kernel's source.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Refusal {
    /// The image is larger than [`MAX_IMAGE`]; refused before any worker is started.
    TooLarge,
    /// `mime` is not an image type this reader accepts.
    UnsupportedMedia(String),
    /// The queue is full right now: the caller retries later (`again`).
    Busy,
    /// The reader answered with a failure of its own (`no_text_detected`, `worker_stalled`, …).
    Failed(String),
    /// The node has no OCR worker provisioned (no interpreter, no script).
    NotProvisioned(String),
}

impl Refusal {
    /// The reason word, for the guest's `failed(reason)` and for this module's log lines.
    pub fn reason(&self) -> String {
        match self {
            Refusal::TooLarge => "image_too_large".into(),
            Refusal::UnsupportedMedia(mime) => format!("unsupported_media:{mime}"),
            Refusal::Busy => "busy".into(),
            Refusal::Failed(reason) => reason.clone(),
            Refusal::NotProvisioned(reason) => reason.clone(),
        }
    }

    /// Is another attempt at the same image pointless? A no-text answer and a refused media type
    /// are answers, not accidents; a stalled/timed-out worker may well succeed on a fresh one.
    pub fn permanent(&self) -> bool {
        match self {
            Refusal::TooLarge | Refusal::UnsupportedMedia(_) => true,
            Refusal::Failed(reason) => matches!(
                reason.as_str(),
                "no_text_detected" | "image_too_large" | "ocr_text_too_long" | "rapidocr_missing" | "offline_model_unavailable" | "unsupported_mode"
            ),
            Refusal::Busy | Refusal::NotProvisioned(_) => false,
        }
    }
}

/// The media types the reader accepts. Anything else is refused before a worker is started: the
/// worker would only fail to decode it, and a document's `application/pdf` is not OCR.
pub fn accepts(mime: &str) -> bool {
    let base = mime.split(';').next().unwrap_or("").trim().to_ascii_lowercase();
    matches!(base.as_str(), "image/jpeg" | "image/jpg" | "image/png" | "image/webp" | "image/bmp" | "image/tiff" | "image/gif")
}

enum Request {
    Read { image: Vec<u8>, mime: String, reply: SyncSender<Result<Reading, Refusal>> },
    /// Start the worker now (engine load) without a job.
    Warm,
}

fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").or_else(|_| std::env::var("USERPROFILE")).unwrap_or_else(|_| ".".into()))
}

fn paths() -> Result<(PathBuf, PathBuf), String> {
    let python = std::env::var("WA_OCR_PYTHON").map(PathBuf::from).unwrap_or_else(|_| home().join(".local/wa-ocr-rapid/bin/python"));
    let worker = match std::env::var("WA_OCR_WORKER") {
        Ok(path) => PathBuf::from(path),
        Err(_) => {
            let tree = std::fs::read_to_string(home().join(".local/bin/runtime-worktree.txt")).map_err(|_| "ocr_worker_not_configured".to_string())?;
            PathBuf::from(tree.trim()).join("scripts/whatsapp-ocr-local.py")
        }
    };
    for (what, path) in [("python", &python), ("worker", &worker)] {
        if !path.is_file() {
            return Err(format!("ocr_{what}_missing"));
        }
    }
    Ok((python, worker))
}

/// Is this node's text reader provisioned (the interpreter and the worker script)? A read on a node
/// without one fails `ocr_not_provisioned` instead of silently answering "no text": a missing reader
/// and an unreadable screenshot are different facts.
pub fn provisioned() -> bool {
    paths().is_ok()
}

fn hub() -> &'static SyncSender<Request> {
    static HUB: OnceLock<SyncSender<Request>> = OnceLock::new();
    HUB.get_or_init(|| {
        let (tx, rx) = mpsc::sync_channel::<Request>(QUEUE_DEPTH);
        let _ = std::thread::Builder::new().name("wa-ocr-hub".into()).spawn(move || run_hub(rx));
        tx
    })
}

/// Read the text in one image. Blocks the calling thread until the worker answers or the deadline
/// passes; the 0.2 host calls it on its own thread and the guest task stays parked
/// (`service_components_v2::wa::kernel::vision`).
pub fn read(image: Vec<u8>, mime: &str) -> Result<Reading, Refusal> {
    if image.len() > MAX_IMAGE {
        return Err(Refusal::TooLarge);
    }
    if image.is_empty() {
        return Err(Refusal::UnsupportedMedia(mime.to_string()));
    }
    if !accepts(mime) {
        return Err(Refusal::UnsupportedMedia(mime.to_string()));
    }
    if let Err(reason) = paths() {
        return Err(Refusal::NotProvisioned(reason));
    }
    let (reply_tx, reply) = mpsc::sync_channel::<Result<Reading, Refusal>>(1);
    let request = Request::Read { image, mime: mime.to_string(), reply: reply_tx };
    enqueue(hub(), request)?;
    match reply.recv_timeout(BUDGET + STALL) {
        Ok(answer) => answer,
        // The hub thread exists but the worker outlived every bound it has: the caller gets a word,
        // not a hang.
        Err(RecvTimeoutError::Timeout) => Err(Refusal::Failed("worker_timeout".into())),
        // The hub died (a panic in a test's fake, a process shutdown): the request went nowhere.
        Err(RecvTimeoutError::Disconnected) => Err(Refusal::Failed("ocr_hub_down".into())),
    }
}

/// Put one request on the bounded queue. A full queue is `busy`, never a block: an image burst must
/// not be able to park the kernel's own thread.
fn enqueue(tx: &SyncSender<Request>, request: Request) -> Result<(), Refusal> {
    match tx.try_send(request) {
        Ok(()) => Ok(()),
        Err(TrySendError::Full(_)) => Err(Refusal::Busy),
        Err(TrySendError::Disconnected(_)) => Err(Refusal::Failed("ocr_hub_down".into())),
    }
}

/// Load the engine now (called when a component holding the `ocr` grant starts). A no-op when the
/// reader is not provisioned on this node; the error surfaces on the first real read instead.
pub fn prewarm() {
    if paths().is_ok() {
        let _ = hub().try_send(Request::Warm);
    }
}

/// A started worker: the process (when there is one) and the two halves of its line protocol.
///
/// `child` is optional and `input` is a boxed writer so a test substitutes a fake worker that speaks
/// the same protocol without an OS process: the production path and the tested path are then the
/// same code, not a mock of it.
struct Warm {
    child: Option<Child>,
    input: Box<dyn Write + Send>,
    lines: Receiver<String>,
}

impl Drop for Warm {
    fn drop(&mut self) {
        if let Some(child) = &mut self.child {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

/// How a worker is started: the real one spawns the Python reader, a test passes a fake that counts
/// the engine loads it is asked for.
type Spawner = fn() -> Result<Warm, String>;

fn spawn() -> Result<Warm, String> {
    let (python, worker) = paths()?;
    // Lower priority than the node's own work, as the recognizer is.
    let mut cmd = if cfg!(unix) && std::path::Path::new("/usr/bin/nice").exists() {
        let mut c = Command::new("/usr/bin/nice");
        c.arg("-n").arg("10").arg(&python);
        c
    } else {
        Command::new(&python)
    };
    // The model pair, when the operator set it, goes through untouched (the worker owns the
    // both-or-neither rule).
    cmd.arg(&worker).arg("--worker");
    for name in ["WA_WHATSAPP_OCR_REC_MODEL", "WA_WHATSAPP_OCR_REC_KEYS", "WA_WHATSAPP_OCR_LANGUAGE"] {
        if let Ok(value) = std::env::var(name) {
            cmd.env(name, value);
        }
    }
    let mut child = cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().map_err(|e| format!("ocr_spawn_failed:{e}"))?;
    let input = child.stdin.take().ok_or("ocr_no_stdin")?;
    let stdout = child.stdout.take().ok_or("ocr_no_stdout")?;
    let (tx, rx) = mpsc::channel();
    std::thread::Builder::new()
        .name("wa-ocr-reader".into())
        .spawn(move || {
            for line in BufReader::new(stdout).lines() {
                match line {
                    Ok(line) => {
                        if tx.send(line).is_err() {
                            return;
                        }
                    }
                    Err(_) => return,
                }
            }
        })
        .map_err(|e| e.to_string())?;
    Ok(Warm { child: Some(child), input: Box::new(input), lines: rx })
}

/// The hub's own state, without its thread: the warm worker, how one is started, how many times a
/// start was needed, and the two deadlines. Every job goes through it, so a test that drives a
/// `Hub` with a fake spawner exercises the production path - including the answers to "does a second
/// image reload the engine?" (it must not) and "what happens when the worker died?" (one new worker,
/// one retry, then the reason).
struct Hub {
    warm: Option<Warm>,
    spawn: Spawner,
    /// Worker starts in this hub - one each, and each one is an engine load. Counted, not inferred.
    loads: u32,
    stall: Duration,
    budget: Duration,
}

impl Hub {
    fn new(spawn: Spawner) -> Hub {
        Hub { warm: None, spawn, loads: 0, stall: STALL, budget: BUDGET }
    }

    #[cfg(test)]
    fn with_deadlines(spawn: Spawner, stall: Duration, budget: Duration) -> Hub {
        Hub { warm: None, spawn, loads: 0, stall, budget }
    }

    /// The warm worker, started now if there is none. The only place an engine load happens.
    fn ensure(&mut self) -> Result<&mut Warm, String> {
        if self.warm.is_none() {
            let worker = (self.spawn)()?;
            self.loads += 1;
            eprintln!("[ocr] worker start #{} (engine load)", self.loads);
            self.warm = Some(worker);
        }
        Ok(self.warm.as_mut().expect("just started"))
    }

    /// The component start's `Request::Warm`: load the engine now, so the first screenshot does not
    /// pay the load. A node with no provisioned reader answers on the first real read instead.
    fn warm_now(&mut self) -> bool {
        self.ensure().is_ok()
    }

    /// One image with the retry rule: a job whose worker died (or stalled) is retried **once** on a
    /// fresh worker; anything else is the answer.
    fn read(&mut self, image: &[u8], mime: &str, n: u64) -> Result<Reading, Refusal> {
        // The two refusals that need no worker, repeated from the public entry point: a caller that
        // reaches the hub another way (a test, a future batch path) gets the same answer, and a
        // 20 MiB image is still never written to a temp file.
        if image.len() > MAX_IMAGE {
            return Err(Refusal::TooLarge);
        }
        if image.is_empty() || !accepts(mime) {
            return Err(Refusal::UnsupportedMedia(mime.to_string()));
        }
        match self.once(image, mime, n) {
            // `Once` already dropped the warm worker, so the retry starts a new one.
            Err(Refusal::Failed(reason)) if is_worker_loss(&reason) => {
                eprintln!("[ocr] job {n}: worker lost ({reason}); retrying once on a new worker");
                self.once(image, mime, n)
            }
            other => other,
        }
    }

    fn once(&mut self, image: &[u8], mime: &str, n: u64) -> Result<Reading, Refusal> {
        let bytes = image.len();
        let path = std::env::temp_dir().join(format!("wa-ocr-{}-{n}.img", std::process::id()));
        if let Err(error) = std::fs::write(&path, image) {
            return Err(Refusal::Failed(format!("ocr_temp_write:{error}")));
        }
        let result = self.run(&path, mime);
        // The image never outlives the read: the old bridge deletes its temp file too.
        let _ = std::fs::remove_file(&path);
        match &result {
            Ok(reading) => eprintln!("[ocr] job {n}: {} bytes -> {} chars in {} ms", bytes, reading.text.chars().count(), reading.elapsed_ms),
            Err(refusal) => eprintln!("[ocr] job {n}: {bytes} bytes refused ({})", refusal.reason()),
        }
        result
    }

    fn run(&mut self, path: &std::path::Path, mime: &str) -> Result<Reading, Refusal> {
        let started = Instant::now();
        // Copied out before `ensure` borrows the hub: the two deadlines are plain numbers, and a
        // borrowed hub while the worker's pipe is read would not compile (nor be clearer).
        let (stall, budget) = (self.stall, self.budget);
        let w = match self.ensure() {
            Ok(w) => w,
            Err(error) => return Err(Refusal::NotProvisioned(error)),
        };
        let line = serde_json::json!({"input": path.to_string_lossy(), "mode": "ocr", "mime": mime}).to_string();
        if writeln!(w.input, "{line}").and_then(|_| w.input.flush()).is_err() {
            self.warm = None;
            return Err(Refusal::Failed("worker_eof".into()));
        }
        let deadline = started + budget;
        // One request, one answer: the OCR worker's line protocol has no progress lines (unlike the
        // recognizer's segment stream), so there is nothing to loop over - the first line is the
        // answer, whatever it says.
        let wait = stall.min(deadline.saturating_duration_since(Instant::now()));
        match w.lines.recv_timeout(wait) {
            Ok(text) => {
                let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) else {
                    self.warm = None;
                    return Err(Refusal::Failed("worker_protocol".into()));
                };
                if value["ok"] == serde_json::json!(true) {
                    // No text is the reader's `no_text_detected`, not an empty reading: an empty
                    // string attached to an index record would say "this image has no words".
                    let text = value["text"].as_str().unwrap_or("").trim();
                    if text.is_empty() {
                        return Err(Refusal::Failed("no_text_detected".into()));
                    }
                    return Ok(Reading { text: text.to_string(), mime: mime.to_string(), elapsed_ms: started.elapsed().as_millis() as u64 });
                }
                Err(Refusal::Failed(value["error"].as_str().unwrap_or("local_compute_unavailable").to_string()))
            }
            Err(RecvTimeoutError::Timeout) => {
                // A worker that produced no line within the stall window or the budget is dead
                // weight: drop it (kill on drop) so the next job starts a fresh one.
                self.warm = None;
                Err(Refusal::Failed(if Instant::now() >= deadline { "worker_timeout" } else { "worker_stalled" }.into()))
            }
            Err(RecvTimeoutError::Disconnected) => {
                self.warm = None;
                Err(Refusal::Failed("worker_eof".into()))
            }
        }
    }
}

/// Did this failure lose the worker (so one retry on a new one is warranted)?
fn is_worker_loss(reason: &str) -> bool {
    matches!(reason, "worker_eof" | "worker_stalled" | "worker_timeout" | "worker_protocol")
}

fn run_hub(rx: Receiver<Request>) {
    let mut hub = Hub::new(spawn);
    let mut counter = 0u64;
    for request in rx {
        match request {
            Request::Warm => {
                hub.warm_now();
            }
            Request::Read { image, mime, reply } => {
                counter += 1;
                let outcome = hub.read(&image, &mime, counter);
                // A caller that gave up is not an error in the kernel: the answer has nowhere to go.
                let _ = reply.send(outcome);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// Serialises the tests that read a fake worker's process-wide load counter.
    fn exclusive() -> std::sync::MutexGuard<'static, ()> {
        static GATE: std::sync::Mutex<()> = std::sync::Mutex::new(());
        GATE.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// The `Write` half of a fake worker pipe: complete lines become requests, the way the real
    /// worker reads stdin. `writeln!` writes the text and the newline separately, so the buffer is
    /// kept between writes.
    struct Pipe {
        pending: String,
        requests: mpsc::Sender<String>,
    }

    impl std::io::Write for Pipe {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.pending.push_str(&String::from_utf8_lossy(buf));
            while let Some(at) = self.pending.find('\n') {
                let line: String = self.pending.drain(..=at).collect();
                let _ = self.requests.send(line.trim().to_string());
            }
            Ok(buf.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    /// Engine loads of the fake readers below: one per worker start, which is what a stopped or
    /// restarted worker costs on a node.
    static LIVE_LOADS: AtomicUsize = AtomicUsize::new(0);
    static CRASH_LOADS: AtomicUsize = AtomicUsize::new(0);
    static DEAD_LOADS: AtomicUsize = AtomicUsize::new(0);

    /// A worker that loads the engine once per start (counted) and then answers every request the
    /// way `scripts/whatsapp-ocr-local.py --worker` does: one line with the text.
    fn fake_spawn() -> Result<Warm, String> {
        LIVE_LOADS.fetch_add(1, Ordering::SeqCst);
        let (requests, requests_rx) = mpsc::channel::<String>();
        let (lines, line_rx) = mpsc::channel::<String>();
        std::thread::Builder::new()
            .name("fake-ocr".into())
            .spawn(move || {
                for request in requests_rx {
                    let _value: serde_json::Value = serde_json::from_str(&request).unwrap_or_default();
                    let _ = lines.send(serde_json::json!({"ok": true, "text": "SUPERMERCADO CENTRAL 12,90", "language": "pt", "local_only": true, "mode": "ocr"}).to_string());
                }
            })
            .expect("fake worker thread");
        Ok(Warm { child: None, input: Box::new(Pipe { pending: String::new(), requests }), lines: line_rx })
    }

    /// A worker that reads nothing: the protocol answer a screenshot with no words gets.
    fn no_text_spawn() -> Result<Warm, String> {
        let (requests, requests_rx) = mpsc::channel::<String>();
        let (lines, line_rx) = mpsc::channel::<String>();
        std::thread::Builder::new()
            .name("fake-ocr-empty".into())
            .spawn(move || {
                for _request in requests_rx {
                    let _ = lines.send(serde_json::json!({"ok": false, "error": "no_text_detected"}).to_string());
                }
            })
            .expect("fake worker thread");
        Ok(Warm { child: None, input: Box::new(Pipe { pending: String::new(), requests }), lines: line_rx })
    }

    /// The first worker dies on the first job (its reader is closed, exactly what a crashed process
    /// looks like), every worker after it is the answering one.
    fn crash_once_spawn() -> Result<Warm, String> {
        if CRASH_LOADS.fetch_add(1, Ordering::SeqCst) == 0 {
            let (requests, requests_rx) = mpsc::channel::<String>();
            drop(requests_rx);
            let (_lines, line_rx) = mpsc::channel::<String>();
            return Ok(Warm { child: None, input: Box::new(Pipe { pending: String::new(), requests }), lines: line_rx });
        }
        fake_spawn()
    }

    /// A worker that is already gone and stays gone: every job behind it fails.
    fn dead_spawn() -> Result<Warm, String> {
        DEAD_LOADS.fetch_add(1, Ordering::SeqCst);
        let (requests, requests_rx) = mpsc::channel::<String>();
        drop(requests_rx);
        let (_lines, line_rx) = mpsc::channel::<String>();
        Ok(Warm { child: None, input: Box::new(Pipe { pending: String::new(), requests }), lines: line_rx })
    }

    /// A worker that accepts the request and never answers: a wedged engine. Its line pipe stays
    /// open (the sender is held by the thread), so the hub sees a stall, not an EOF.
    fn mute_spawn() -> Result<Warm, String> {
        let (lines, line_rx) = mpsc::channel::<String>();
        let (requests, requests_rx) = mpsc::channel::<String>();
        std::thread::Builder::new()
            .name("mute-ocr".into())
            .spawn(move || {
                let _keep_open = lines;
                while requests_rx.recv().is_ok() {}
            })
            .expect("fake worker thread");
        Ok(Warm { child: None, input: Box::new(Pipe { pending: String::new(), requests }), lines: line_rx })
    }

    fn image() -> Vec<u8> {
        // Not a real JPEG: the fake workers never decode, and what is tested is the kernel's own
        // path (size, mime, queue, retry), not the model.
        vec![0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10]
    }

    #[test]
    fn a_second_image_does_not_reload_the_engine() {
        let _gate = exclusive();
        LIVE_LOADS.store(0, Ordering::SeqCst);
        let mut hub = Hub::new(fake_spawn);
        assert!(hub.warm_now(), "the component start warms the reader (Request::Warm)");
        assert_eq!(hub.loads, 1, "warming costs exactly one load");

        for n in 1..=2u64 {
            let reading = hub.read(&image(), "image/jpeg", n).expect("the fake reader answers");
            // The text travels unchanged: the same worker script the old bridge runs is the parity
            // claim, so nothing in the kernel may rewrite it.
            assert_eq!(reading.text, "SUPERMERCADO CENTRAL 12,90", "job {n}");
            assert_eq!(reading.mime, "image/jpeg");
        }
        assert_eq!(hub.loads, 1, "the second image reused the warm worker");
        assert_eq!(LIVE_LOADS.load(Ordering::SeqCst), 1, "one engine load for two images");
    }

    #[test]
    fn a_first_image_without_a_prewarm_loads_once_and_the_next_reuses_it() {
        let _gate = exclusive();
        LIVE_LOADS.store(0, Ordering::SeqCst);
        let mut hub = Hub::new(fake_spawn);
        for n in 1..=2u64 {
            assert!(hub.read(&image(), "image/png", n).is_ok());
        }
        assert_eq!(hub.loads, 1, "the first read loaded, the second did not");
        assert_eq!(LIVE_LOADS.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn a_crashed_worker_is_restarted_and_the_job_retried_once() {
        let _gate = exclusive();
        CRASH_LOADS.store(0, Ordering::SeqCst);
        let mut hub = Hub::new(crash_once_spawn);
        let reading = hub.read(&image(), "image/jpeg", 1).expect("the retry on a fresh worker answered");
        assert_eq!(reading.text, "SUPERMERCADO CENTRAL 12,90");
        assert_eq!(hub.loads, 2, "the dead worker was replaced exactly once");
        assert_eq!(CRASH_LOADS.load(Ordering::SeqCst), 2, "one dead start and one live start");
    }

    #[test]
    fn a_worker_that_stays_dead_fails_after_one_retry_instead_of_looping() {
        let _gate = exclusive();
        DEAD_LOADS.store(0, Ordering::SeqCst);
        let mut hub = Hub::new(dead_spawn);
        assert_eq!(hub.read(&image(), "image/jpeg", 1), Err(Refusal::Failed("worker_eof".into())));
        assert_eq!(DEAD_LOADS.load(Ordering::SeqCst), 2, "the retry started exactly one replacement");
        assert!(hub.warm.is_none(), "a dead worker is dropped, so the next job starts one");
        // The next job is a fresh attempt (two more starts), not a silent reuse of a dead pipe.
        assert_eq!(hub.read(&image(), "image/jpeg", 2), Err(Refusal::Failed("worker_eof".into())));
        assert_eq!(DEAD_LOADS.load(Ordering::SeqCst), 4);
    }

    #[test]
    fn a_stalled_worker_is_dropped_and_counts_as_a_failure() {
        let _gate = exclusive();
        let mut hub = Hub::with_deadlines(mute_spawn, Duration::from_millis(40), Duration::from_millis(60));
        let refusal = hub.read(&image(), "image/jpeg", 1).unwrap_err();
        assert!(matches!(refusal, Refusal::Failed(ref reason) if reason == "worker_stalled" || reason == "worker_timeout"), "{refusal:?}");
        assert!(hub.warm.is_none(), "a stalled worker is killed and forgotten");
        assert_eq!(hub.loads, 2, "the stall was retried once on a new worker");
    }

    #[test]
    fn no_text_is_a_failure_not_an_empty_reading() {
        let _gate = exclusive();
        let mut hub = Hub::new(no_text_spawn);
        assert_eq!(hub.read(&image(), "image/jpeg", 1), Err(Refusal::Failed("no_text_detected".into())));
        assert!(Refusal::Failed("no_text_detected".into()).permanent(), "the same image will not start reading");
        assert!(!Refusal::Failed("worker_stalled".into()).permanent(), "a fresh worker may read it");
    }

    #[test]
    fn an_oversized_image_is_refused_cleanly_before_any_worker_starts() {
        let _gate = exclusive();
        LIVE_LOADS.store(0, Ordering::SeqCst);
        let mut hub = Hub::new(fake_spawn);
        let big = vec![0u8; MAX_IMAGE + 1];
        assert_eq!(hub.read(&big, "image/jpeg", 1), Err(Refusal::TooLarge));
        assert_eq!(hub.loads, 0, "the reader was never started");
        assert_eq!(LIVE_LOADS.load(Ordering::SeqCst), 0);
        assert_eq!(Refusal::TooLarge.reason(), "image_too_large");
        assert!(Refusal::TooLarge.permanent());
        // The public entry point refuses it before a hub exists at all, so a node that never reads
        // images pays nothing for the check.
        assert_eq!(read(big, "image/jpeg"), Err(Refusal::TooLarge));
    }

    #[test]
    fn a_non_image_type_is_refused_rather_than_decoded() {
        assert!(accepts("image/jpeg"));
        assert!(accepts("IMAGE/PNG; q=1"));
        assert!(!accepts("application/pdf"));
        assert!(!accepts("audio/ogg"));
        assert!(!accepts(""));
        assert_eq!(read(image(), "application/pdf"), Err(Refusal::UnsupportedMedia("application/pdf".into())));
    }

    #[test]
    fn the_queue_is_bounded_so_a_burst_cannot_park_the_kernel() {
        // A full channel is `busy`, which the guest answers as `again`; nothing blocks.
        let (tx, rx) = mpsc::sync_channel::<Request>(1);
        let (reply, _) = mpsc::sync_channel(1);
        assert!(enqueue(&tx, Request::Warm).is_ok());
        let overflow = enqueue(&tx, Request::Read { image: image(), mime: "image/jpeg".into(), reply });
        assert_eq!(overflow, Err(Refusal::Busy));
        assert_eq!(Refusal::Busy.reason(), "busy");
        assert!(!Refusal::Busy.permanent(), "a full queue is a retry, not a refusal of the image");
        drop(rx);
        // A hub that is gone is a failure the caller can name, not a panic.
        assert_eq!(enqueue(&tx, Request::Warm), Err(Refusal::Failed("ocr_hub_down".into())));
    }

    /// The reply channel is the path the 0.2 host actually uses: `read` on a hub thread and one
    /// request in, one answer back. This drives `enqueue` + `recv_timeout` without a global hub, so
    /// two tests can never share a worker.
    #[test]
    fn a_request_travels_the_bounded_queue_and_answers_the_caller() {
        let _gate = exclusive();
        LIVE_LOADS.store(0, Ordering::SeqCst);
        let (tx, rx) = mpsc::sync_channel::<Request>(QUEUE_DEPTH);
        let hub_thread = std::thread::spawn(move || {
            let mut hub = Hub::new(fake_spawn);
            for request in rx {
                match request {
                    Request::Warm => {
                        hub.warm_now();
                    }
                    Request::Read { image, mime, reply } => {
                        let _ = reply.send(hub.read(&image, &mime, 1));
                    }
                }
            }
        });
        assert!(enqueue(&tx, Request::Warm).is_ok(), "the component start warms it");
        let (reply_tx, reply) = mpsc::sync_channel(1);
        enqueue(&tx, Request::Read { image: image(), mime: "image/jpeg".into(), reply: reply_tx }).expect("queued");
        let reading = reply.recv_timeout(Duration::from_secs(5)).expect("the hub answers").expect("the fake reader read it");
        assert_eq!(reading.text, "SUPERMERCADO CENTRAL 12,90");
        drop(tx);
        hub_thread.join().expect("the hub ends when its queue is dropped");
        assert_eq!(LIVE_LOADS.load(Ordering::SeqCst), 1, "warming and the read shared one worker");
    }
}
