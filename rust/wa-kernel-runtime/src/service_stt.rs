//! `wa:kernel/speech` for service components: the node's native recognizer (the faster-whisper
//! worker the WhatsApp connector provisions, `scripts/whatsapp-stt-local.py --worker`) behind a
//! non-blocking job API. One warm worker per host process, one request at a time (a 2-core node
//! cannot afford more), started on first use under `nice -n 10` so the node's other work keeps
//! priority. The worker stays warm: it is started as soon as a component with the `stt` grant starts
//! (`prewarm`), so the first voice note does not pay the model load (~16 s on openclaw), and it is
//! stopped after idle only when WA_STT_IDLE_SECONDS > 0 (default 0 = never). Same liveness rules as
//! connectors/whatsapp/worker.go: killed only when stuck (no line for `STALL`) or past
//! `BUDGET_BASE + BUDGET_PER_AUDIO * seconds`.
//!
//! Streaming: every request asks the worker for segment text (`"segments": true`); each recognized
//! segment lands in the job's `segments` as it is decoded, so a consumer can show text before the
//! whole note is done. Segment text travels only over the worker pipe, never into a log.
//!
//! Paths (references, never secrets): WA_STT_PYTHON (default ~/.local/wa-stt/bin/python),
//! WA_STT_MODELS (default ~/.local/share/wa-stt/models), WA_STT_WORKER (default
//! <runtime worktree>/scripts/whatsapp-stt-local.py, the worktree named by
//! ~/.local/bin/runtime-worktree.txt).
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

const STALL: Duration = Duration::from_secs(180);
const BUDGET_BASE: Duration = Duration::from_secs(300);
const BUDGET_PER_AUDIO: f64 = 6.0;
const MAX_AUDIO: usize = 20 << 20;

#[derive(Clone, Debug, PartialEq)]
pub enum JobState {
    Queued,
    Done { text: String, elapsed_ms: u64 },
    Failed(String),
}

/// A job's state plus the segment texts recognized so far (in order).
#[derive(Debug)]
pub struct Job {
    pub state: JobState,
    pub segments: Vec<String>,
    /// Longest audio duration the worker has reported, milliseconds (0 = not reported yet): the
    /// audio position of the last segment, which is what a 0.2 segment's `end-ms` names.
    pub duration_ms: u64,
    /// Wakes the 0.2 guest task waiting on the segments stream or on the result future.
    pub notify: std::sync::Arc<crate::service_io::Notify>,
}

impl Job {
    /// Record one recognized segment (0.2 streams it, 0.1 polls for it).
    pub(crate) fn push_segment(&mut self, text: String, duration_ms: Option<u64>) {
        self.segments.push(text);
        if let Some(ms) = duration_ms {
            self.duration_ms = self.duration_ms.max(ms);
        }
        self.notify.notify();
    }

    /// Move the job to its terminal state and wake the waiter.
    pub fn finish(&mut self, state: JobState) {
        self.state = state;
        self.notify.notify();
    }
}

pub type JobSlot = Arc<Mutex<Job>>;

enum Request {
    Recognize { audio: Vec<u8>, ext: &'static str, language: String, slot: JobSlot },
    /// Start the worker now (model load) without a job.
    Warm,
}

/// Idle shutdown from a raw setting: absent, empty, `0` or anything unparseable means **never** -
/// which is the default, because a warm model is the point (a stopped worker pays ~16 s on the next
/// note). A positive number of seconds is how long it may sit unused before the worker is stopped.
fn idle_from(raw: Option<&str>) -> Option<Duration> {
    raw.and_then(|value| value.trim().parse::<u64>().ok()).filter(|seconds| *seconds > 0).map(Duration::from_secs)
}

/// Idle time after which the warm worker is stopped; None = never (the default).
fn idle() -> Option<Duration> {
    idle_from(std::env::var("WA_STT_IDLE_SECONDS").ok().as_deref())
}

fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").or_else(|_| std::env::var("USERPROFILE")).unwrap_or_else(|_| ".".into()))
}

fn paths() -> Result<(PathBuf, PathBuf, PathBuf), String> {
    let python = std::env::var("WA_STT_PYTHON").map(PathBuf::from).unwrap_or_else(|_| home().join(".local/wa-stt/bin/python"));
    let models = std::env::var("WA_STT_MODELS").map(PathBuf::from).unwrap_or_else(|_| home().join(".local/share/wa-stt/models"));
    let worker = match std::env::var("WA_STT_WORKER") {
        Ok(path) => PathBuf::from(path),
        Err(_) => {
            let tree = std::fs::read_to_string(home().join(".local/bin/runtime-worktree.txt")).map_err(|_| "stt_worker_not_configured".to_string())?;
            PathBuf::from(tree.trim()).join("scripts/whatsapp-stt-local.py")
        }
    };
    for (what, path) in [("python", &python), ("worker", &worker)] {
        if !path.is_file() {
            return Err(format!("stt_{what}_missing"));
        }
    }
    if !models.is_dir() {
        return Err("stt_models_missing".into());
    }
    Ok((python, worker, models))
}

fn hub() -> &'static Sender<Request> {
    static HUB: OnceLock<Sender<Request>> = OnceLock::new();
    HUB.get_or_init(|| {
        let (tx, rx) = mpsc::channel::<Request>();
        let _ = std::thread::Builder::new().name("wa-stt-hub".into()).spawn(move || run_hub(rx));
        tx
    })
}

/// A queued job with no work behind it yet: the slot a caller polls.
pub(crate) fn new_slot() -> JobSlot {
    Arc::new(Mutex::new(Job { state: JobState::Queued, segments: Vec::new(), duration_ms: 0, notify: crate::service_io::Notify::new() }))
}

/// Is this node's recognizer provisioned (the interpreter, the worker script and the model cache)?
/// A worker node that would fail every job it takes asks first (`stt_node`'s remote loop).
pub(crate) fn provisioned() -> bool {
    paths().is_ok()
}

/// Queue one recognition; the returned slot moves from Queued to Done/Failed.
///
/// On a node that runs the shared queue (`lua/core/stt.lua` configured a producer, `docs/QUEUE.md`
/// "Phase 2") the request becomes a job on `stt.requests`: a remote `stt_worker` may take it, and
/// this node's own warm worker takes it after the policy grace if none does. The slot the caller
/// polls is filled from the job either way (`stt_node::mirror`). A node without the queue — the
/// codemode/root interpreter, a test host, a worker-only node — keeps the direct warm-worker path,
/// which is the behaviour this function had before the queue existed.
pub fn submit(audio: Vec<u8>, mime: &str, language: &str) -> Result<JobSlot, String> {
    if audio.is_empty() || audio.len() > MAX_AUDIO {
        return Err("audio_too_large".into());
    }
    if !crate::stt_node::producing() {
        return decode_direct(audio, mime, language);
    }
    let slot = new_slot();
    let mime = wa_stt_remote::request::Mime::parse(mime).unwrap_or(wa_stt_remote::request::Mime::Ogg);
    let submission = crate::stt_node::Submission::from_audio(audio.clone(), mime, language);
    match crate::stt_node::enqueue(submission, Some(slot.clone())) {
        Ok(_job) => Ok(slot),
        // A note past its window is never decoded by anyone: the caller turns this into the
        // own-chat `audio_expired` alert instead of a transcript posted late.
        Err(crate::stt_node::EnqueueProblem::Stale { .. }) => Err("stale_job".into()),
        Err(crate::stt_node::EnqueueProblem::Unavailable(reason)) => {
            // The queue is not usable in this process. Decoding here is the honest fallback: the
            // note still gets its transcript, and the reason is visible on stderr.
            eprintln!("[stt] queue unavailable ({reason}); decoding in this process");
            decode_direct(audio, mime_str(mime), language)
        }
    }
}

fn mime_str(mime: wa_stt_remote::request::Mime) -> &'static str {
    mime.as_str()
}

/// Run one recognition on this process's warm worker without the queue (the pre-queue path).
pub(crate) fn decode_direct(audio: Vec<u8>, mime: &str, language: &str) -> Result<JobSlot, String> {
    paths()?;
    let ext = match mime.split(';').next().unwrap_or("").trim() {
        "audio/mpeg" | "audio/mp3" => "mp3",
        "audio/wav" | "audio/x-wav" => "wav",
        "audio/mp4" | "audio/aac" | "audio/m4a" => "m4a",
        _ => "ogg",
    };
    let slot = new_slot();
    hub().send(Request::Recognize { audio, ext, language: language.to_string(), slot: slot.clone() }).map_err(|_| "stt_hub_down".to_string())?;
    Ok(slot)
}

/// Load the model now (called when a component holding the `stt` grant starts). A no-op when the
/// recognizer is not provisioned on this node; errors surface on the first real job instead.
pub fn prewarm() {
    if paths().is_ok() {
        let _ = hub().send(Request::Warm);
    }
}

/// A started worker: the process (when there is one) and the two halves of its line protocol.
///
/// `child` is optional and `input` is a boxed writer so a test can substitute a fake worker that
/// speaks the same protocol without an OS process: the production path and the tested path are
/// then the same code, not a mock of it.
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

/// How a worker is started. The real one spawns the Python recognizer; a test passes a fake that
/// counts the model loads it is asked for.
type Spawner = fn() -> Result<Warm, String>;

fn spawn() -> Result<Warm, String> {
    let (python, worker, models) = paths()?;
    // Lower priority than everything else on the node (the native connector's own workers).
    let mut cmd = if cfg!(unix) && std::path::Path::new("/usr/bin/nice").exists() {
        let mut c = Command::new("/usr/bin/nice");
        c.arg("-n").arg("10").arg(&python);
        c
    } else {
        Command::new(&python)
    };
    cmd.arg(&worker).arg("--worker").env("HF_HUB_OFFLINE", "1").env("WA_WHATSAPP_STT_MODELS", &models);
    let mut child = cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().map_err(|e| format!("stt_spawn_failed:{e}"))?;
    let input = child.stdin.take().ok_or("stt_no_stdin")?;
    let stdout = child.stdout.take().ok_or("stt_no_stdout")?;
    let (tx, rx) = mpsc::channel();
    std::thread::Builder::new()
        .name("wa-stt-reader".into())
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

/// The hub's own state, without its thread: the warm worker, how one is started, and how many
/// times a start was needed. Every job goes through it, so a test that drives a `Hub` with a fake
/// spawner exercises the production path - including the answer to "does a second job reload the
/// model?" (it must not: `loads` stays where the component start left it).
struct Hub {
    warm: Option<Warm>,
    spawn: Spawner,
    /// Worker starts in this hub - one each, and each one is a model load. Counted, not inferred.
    loads: u32,
}

impl Hub {
    fn new(spawn: Spawner) -> Hub {
        Hub { warm: None, spawn, loads: 0 }
    }

    /// The warm worker, started now if there is none. The only place a model load happens.
    fn ensure(&mut self) -> Result<&mut Warm, String> {
        if self.warm.is_none() {
            let worker = (self.spawn)()?;
            self.loads += 1;
            eprintln!("[stt] worker start #{} (model load)", self.loads);
            self.warm = Some(worker);
        }
        Ok(self.warm.as_mut().expect("just started"))
    }

    /// The component start's `Request::Warm`: load the model now, so the first voice note does not
    /// pay the load. A node with no provisioned recognizer answers an error on the first real job.
    fn warm_now(&mut self) -> bool {
        self.ensure().is_ok()
    }

    /// Run one recognition: write the audio out, then one request line to the worker.
    fn transcribe(&mut self, audio: &[u8], ext: &str, language: &str, slot: &JobSlot, n: u64) -> JobState {
        let path = std::env::temp_dir().join(format!("wa-stt-{}-{n}.{ext}", std::process::id()));
        if let Err(error) = std::fs::write(&path, audio) {
            return JobState::Failed(format!("stt_temp_write:{error}"));
        }
        let result = self.run(&path, language, slot);
        let _ = std::fs::remove_file(&path);
        result
    }

    fn run(&mut self, path: &std::path::Path, language: &str, slot: &JobSlot) -> JobState {
        let w = match self.ensure() {
            Ok(w) => w,
            Err(error) => return JobState::Failed(error),
        };
        let line = serde_json::json!({"input": path.to_string_lossy(), "language": language, "mode": "transcribe", "tier": 0, "segments": true}).to_string();
        if writeln!(w.input, "{line}").and_then(|_| w.input.flush()).is_err() {
            self.warm = None;
            return JobState::Failed("worker_eof".into());
        }
        let started = Instant::now();
        let mut deadline = started + BUDGET_BASE;
        loop {
            let wait = STALL.min(deadline.saturating_duration_since(Instant::now()));
            match w.lines.recv_timeout(wait) {
                Ok(text) => {
                    let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) else {
                        self.warm = None;
                        return JobState::Failed("worker_protocol".into());
                    };
                    if value["progress"] == serde_json::json!(true) {
                        if value["ready"] == serde_json::json!(true) {
                            continue; // the worker's own model-loaded line (prewarm)
                        }
                        let duration_ms = value["duration"].as_f64().filter(|d| *d > 0.0).map(|seconds| (seconds * 1000.0) as u64);
                        if let Some(seconds) = value["duration"].as_f64().filter(|d| *d > 0.0) {
                            deadline = started + BUDGET_BASE + Duration::from_secs_f64(BUDGET_PER_AUDIO * seconds);
                        }
                        if let Some(text) = value["text"].as_str().filter(|t| !t.is_empty()) {
                            slot.lock().unwrap().push_segment(text.to_string(), duration_ms);
                        }
                        continue;
                    }
                    let elapsed_ms = started.elapsed().as_millis() as u64;
                    return if value["ok"] == serde_json::json!(true) {
                        JobState::Done { text: value["transcript"].as_str().unwrap_or("").to_string(), elapsed_ms }
                    } else {
                        JobState::Failed(value["error"].as_str().unwrap_or("worker_compute_failed").to_string())
                    };
                }
                Err(RecvTimeoutError::Timeout) => {
                    self.warm = None;
                    return JobState::Failed(if Instant::now() >= deadline { "worker_timeout" } else { "worker_stalled" }.into());
                }
                Err(RecvTimeoutError::Disconnected) => {
                    self.warm = None;
                    return JobState::Failed("worker_eof".into());
                }
            }
        }
    }
}

fn run_hub(rx: Receiver<Request>) {
    let mut hub = Hub::new(spawn);
    let mut counter = 0u64;
    let idle = idle();
    loop {
        let next = match idle {
            Some(idle) => rx.recv_timeout(idle),
            None => rx.recv().map_err(|_| RecvTimeoutError::Disconnected),
        };
        let request = match next {
            Ok(request) => request,
            Err(RecvTimeoutError::Timeout) => {
                hub.warm = None; // idle: free the model's memory
                continue;
            }
            Err(RecvTimeoutError::Disconnected) => return,
        };
        match request {
            Request::Warm => {
                hub.warm_now();
            }
            Request::Recognize { audio, ext, language, slot } => {
                counter += 1;
                let outcome = hub.transcribe(&audio, ext, &language, &slot, counter);
                slot.lock().unwrap().finish(outcome);
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
        static GATE: Mutex<()> = Mutex::new(());
        GATE.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// A queued job, as `submit` builds one.
    fn slot() -> JobSlot {
        Arc::new(Mutex::new(Job { state: JobState::Queued, segments: Vec::new(), duration_ms: 0, notify: crate::service_io::Notify::new() }))
    }

    /// The `Write` half of a fake worker pipe: complete lines become requests, the way the real
    /// worker reads stdin. Two writes per line are normal (`writeln!`), so the buffer is kept.
    struct Pipe {
        pending: String,
        requests: Sender<String>,
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

    /// The fake recognizer's model loads: one per worker start, which is exactly what a stopped or
    /// restarted worker costs on a node (~16 s on openclaw).
    static FAKE_LOADS: AtomicUsize = AtomicUsize::new(0);

    /// The fake recognizer's own load counter, for the assertions a test makes about the process,
    /// not only about one hub.
    fn fake_loads() -> usize {
        FAKE_LOADS.load(Ordering::SeqCst)
    }

    /// A worker that loads the model once per start (counted) and then answers every request the
    /// way `scripts/whatsapp-stt-local.py --worker` does: a `ready` line, one segment line carrying
    /// the streamed text, and one final line with the whole transcript.
    fn fake_spawn() -> Result<Warm, String> {
        FAKE_LOADS.fetch_add(1, Ordering::SeqCst);
        let (requests, requests_rx) = mpsc::channel::<String>();
        let (lines, line_rx) = mpsc::channel::<String>();
        std::thread::Builder::new()
            .name("fake-stt".into())
            .spawn(move || {
                for request in requests_rx {
                    let value: serde_json::Value = serde_json::from_str(&request).unwrap_or_default();
                    let language = value["language"].as_str().unwrap_or("pt").to_string();
                    let _ = lines.send(serde_json::json!({"progress": true, "ready": true}).to_string());
                    let _ = lines.send(serde_json::json!({"progress": true, "at": 2.0, "duration": 2.0, "text": format!("trecho {language}")}).to_string());
                    let _ = lines.send(serde_json::json!({"ok": true, "transcript": format!("trecho {language} inteiro")}).to_string());
                }
            })
            .expect("fake worker thread");
        Ok(Warm { child: None, input: Box::new(Pipe { pending: String::new(), requests }), lines: line_rx })
    }

    /// A worker that is already gone: the request line goes nowhere and the reader is closed, which
    /// is what a crashed worker looks like to the hub.
    static DEAD_LOADS: AtomicUsize = AtomicUsize::new(0);

    fn dead_spawn() -> Result<Warm, String> {
        DEAD_LOADS.fetch_add(1, Ordering::SeqCst);
        let (_lines, line_rx) = mpsc::channel::<String>();
        let (requests, requests_rx) = mpsc::channel::<String>();
        drop(requests_rx);
        Ok(Warm { child: None, input: Box::new(Pipe { pending: String::new(), requests }), lines: line_rx })
    }

    #[test]
    fn a_second_job_does_not_reload_the_model() {
        let _gate = exclusive();
        FAKE_LOADS.store(0, Ordering::SeqCst);
        let mut hub = Hub::new(fake_spawn);
        assert!(hub.warm_now(), "the component start warms the recognizer (Request::Warm)");
        assert_eq!(hub.loads, 1, "warming costs exactly one load");

        for (n, language) in [(1u64, "pt"), (2u64, "en")] {
            let job = slot();
            let state = hub.transcribe(b"audio-bytes", "ogg", language, &job, n);
            assert!(matches!(&state, JobState::Done { text, .. } if text == &format!("trecho {language} inteiro")), "job {n}: {state:?}");
            let job = job.lock().unwrap();
            assert_eq!(job.segments, vec![format!("trecho {language}")], "the segment stream reached the job");
            assert_eq!(job.duration_ms, 2_000, "the duration the worker reported is kept");
        }
        assert_eq!(hub.loads, 1, "the second job reused the warm worker");
        assert_eq!(fake_loads(), 1, "one model load for two jobs");
    }

    #[test]
    fn a_first_job_without_a_prewarm_loads_once_and_the_next_reuses_it() {
        let _gate = exclusive();
        FAKE_LOADS.store(0, Ordering::SeqCst);
        let mut hub = Hub::new(fake_spawn);
        for n in 1..=2u64 {
            let job = slot();
            assert!(matches!(hub.transcribe(b"audio-bytes", "ogg", "pt", &job, n), JobState::Done { .. }));
        }
        assert_eq!(hub.loads, 1, "the first job loaded, the second did not");
        assert_eq!(fake_loads(), 1);
    }

    #[test]
    fn a_dead_worker_is_replaced_and_counts_as_a_new_load() {
        let _gate = exclusive();
        FAKE_LOADS.store(0, Ordering::SeqCst);
        DEAD_LOADS.store(0, Ordering::SeqCst);

        // A live worker serves both jobs from one load.
        let mut live = Hub::new(fake_spawn);
        live.warm_now();
        for n in 1..=2u64 {
            let job = slot();
            assert!(matches!(live.transcribe(b"a", "ogg", "pt", &job, n), JobState::Done { .. }));
        }
        assert_eq!(live.loads, 1, "no reload while the worker is warm");

        // A worker that died makes every job behind it load again: the contrast is the point.
        let mut dead = Hub::new(dead_spawn);
        let job = slot();
        assert_eq!(dead.transcribe(b"a", "ogg", "pt", &job, 1), JobState::Failed("worker_eof".into()));
        assert!(dead.warm.is_none(), "a dead worker is dropped, so the next job starts one");
        let job = slot();
        assert_eq!(dead.transcribe(b"a", "ogg", "pt", &job, 2), JobState::Failed("worker_eof".into()));
        assert_eq!(dead.loads, 2, "each job behind a dead worker loads the model again");
        assert_eq!(DEAD_LOADS.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn idle_shutdown_is_off_by_default_and_configurable() {
        assert_eq!(idle_from(None), None, "the default is a worker that stays warm");
        assert_eq!(idle_from(Some("")), None);
        assert_eq!(idle_from(Some("0")), None, "0 means never, not 'stop at once'");
        assert_eq!(idle_from(Some("nonsense")), None, "an unreadable setting keeps the worker warm");
        assert_eq!(idle_from(Some(" 600 ")), Some(Duration::from_secs(600)));
    }
}
