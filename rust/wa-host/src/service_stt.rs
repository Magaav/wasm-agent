//! `wa:kernel/speech` for service components: the node's native recognizer (the faster-whisper
//! worker the WhatsApp connector provisions, `scripts/whatsapp-stt-local.py --worker`) behind a
//! non-blocking job API. One warm worker per host process, one request at a time (a 2-core node
//! cannot afford more), started on first use under `nice -n 10` so the node's other work keeps
//! priority, stopped after `IDLE` without jobs. Same liveness rules as connectors/whatsapp/worker.go:
//! killed only when stuck (no line for `STALL`) or past `BUDGET_BASE + BUDGET_PER_AUDIO * seconds`.
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
const IDLE: Duration = Duration::from_secs(300);
const MAX_AUDIO: usize = 20 << 20;

#[derive(Clone, Debug)]
pub enum JobState {
    Queued,
    Done { text: String, elapsed_ms: u64 },
    Failed(String),
}

pub type JobSlot = Arc<Mutex<JobState>>;

struct Request {
    audio: Vec<u8>,
    ext: &'static str,
    language: String,
    slot: JobSlot,
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
    let slot = Arc::new(Mutex::new(JobState::Queued));
    hub().send(Request { audio, ext, language: language.to_string(), slot: slot.clone() }).map_err(|_| "stt_hub_down".to_string())?;
    Ok(slot)
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
    loop {
        let request = match rx.recv_timeout(IDLE) {
            Ok(request) => request,
            Err(RecvTimeoutError::Timeout) => {
                warm = None; // idle: free the model's memory
                continue;
            }
            Err(RecvTimeoutError::Disconnected) => return,
        };
        counter += 1;
        let outcome = transcribe(&mut warm, &request, counter);
        *request.slot.lock().unwrap() = outcome;
    }
}

fn transcribe(warm: &mut Option<Warm>, request: &Request, n: u64) -> JobState {
    let path = std::env::temp_dir().join(format!("wa-stt-{}-{n}.{}", std::process::id(), request.ext));
    if let Err(error) = std::fs::write(&path, &request.audio) {
        return JobState::Failed(format!("stt_temp_write:{error}"));
    }
    let result = run_one(warm, &path, &request.language);
    let _ = std::fs::remove_file(&path);
    result
}

fn run_one(warm: &mut Option<Warm>, path: &std::path::Path, language: &str) -> JobState {
    if warm.is_none() {
        match spawn() {
            Ok(w) => *warm = Some(w),
            Err(error) => return JobState::Failed(error),
        }
    }
    let w = warm.as_mut().expect("spawned");
    let line = serde_json::json!({"input": path.to_string_lossy(), "language": language, "mode": "transcribe", "tier": 0}).to_string();
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
                    if let Some(seconds) = value["duration"].as_f64().filter(|d| *d > 0.0) {
                        deadline = started + BUDGET_BASE + Duration::from_secs_f64(BUDGET_PER_AUDIO * seconds);
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
