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
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

const STALL: Duration = Duration::from_secs(180);
const BUDGET_BASE: Duration = Duration::from_secs(300);
const BUDGET_PER_AUDIO: f64 = 6.0;
const MAX_AUDIO: usize = 20 << 20;

#[derive(Clone, Debug)]
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
    fn push_segment(&mut self, text: String, duration_ms: Option<u64>) {
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

/// Idle time after which the warm worker is stopped; None = never (the default).
fn idle() -> Option<Duration> {
    std::env::var("WA_STT_IDLE_SECONDS").ok().and_then(|v| v.trim().parse::<u64>().ok()).filter(|s| *s > 0).map(Duration::from_secs)
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

/// Queue one recognition; the returned slot moves from Queued to Done/Failed.
pub fn submit(audio: Vec<u8>, mime: &str, language: &str) -> Result<JobSlot, String> {
    if audio.is_empty() || audio.len() > MAX_AUDIO {
        return Err("audio_too_large".into());
    }
    paths()?;
    let ext = match mime.split(';').next().unwrap_or("").trim() {
        "audio/mpeg" | "audio/mp3" => "mp3",
        "audio/wav" | "audio/x-wav" => "wav",
        "audio/mp4" | "audio/aac" | "audio/m4a" => "m4a",
        _ => "ogg",
    };
    let slot = Arc::new(Mutex::new(Job { state: JobState::Queued, segments: Vec::new(), duration_ms: 0, notify: crate::service_io::Notify::new() }));
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

struct Warm {
    child: Child,
    input: ChildStdin,
    lines: Receiver<String>,
}

impl Drop for Warm {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

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
    Ok(Warm { child, input, lines: rx })
}

fn run_hub(rx: Receiver<Request>) {
    let mut warm: Option<Warm> = None;
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
                warm = None; // idle: free the model's memory
                continue;
            }
            Err(RecvTimeoutError::Disconnected) => return,
        };
        match request {
            Request::Warm => {
                if warm.is_none() {
                    warm = spawn().ok();
                }
            }
            Request::Recognize { audio, ext, language, slot } => {
                counter += 1;
                let outcome = transcribe(&mut warm, &audio, ext, &language, &slot, counter);
                slot.lock().unwrap().finish(outcome);
            }
        }
    }
}

fn transcribe(warm: &mut Option<Warm>, audio: &[u8], ext: &str, language: &str, slot: &JobSlot, n: u64) -> JobState {
    let path = std::env::temp_dir().join(format!("wa-stt-{}-{n}.{ext}", std::process::id()));
    if let Err(error) = std::fs::write(&path, audio) {
        return JobState::Failed(format!("stt_temp_write:{error}"));
    }
    let result = run_one(warm, &path, language, slot);
    let _ = std::fs::remove_file(&path);
    result
}

fn run_one(warm: &mut Option<Warm>, path: &std::path::Path, language: &str, slot: &JobSlot) -> JobState {
    if warm.is_none() {
        match spawn() {
            Ok(w) => *warm = Some(w),
            Err(error) => return JobState::Failed(error),
        }
    }
    let w = warm.as_mut().expect("spawned");
    let line = serde_json::json!({"input": path.to_string_lossy(), "language": language, "mode": "transcribe", "tier": 0, "segments": true}).to_string();
    if writeln!(w.input, "{line}").and_then(|_| w.input.flush()).is_err() {
        *warm = None;
        return JobState::Failed("worker_eof".into());
    }
    let started = Instant::now();
    let mut deadline = started + BUDGET_BASE;
    loop {
        let wait = STALL.min(deadline.saturating_duration_since(Instant::now()));
        match w.lines.recv_timeout(wait) {
            Ok(text) => {
                let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) else {
                    *warm = None;
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
                *warm = None;
                return JobState::Failed(if Instant::now() >= deadline { "worker_timeout" } else { "worker_stalled" }.into());
            }
            Err(RecvTimeoutError::Disconnected) => {
                *warm = None;
                return JobState::Failed("worker_eof".into());
            }
        }
    }
}
