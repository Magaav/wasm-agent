//! Fixture service on `wa:kernel@0.2` for the **drained hot swap** (`docs/SERVICE-COMPONENTS.md`,
//! "A swap waits for the work in flight"; `rust/wa-kernel-runtime/src/drain.rs`).
//!
//! It does one job at a time on `wa.drain`, slowly enough that a swap can arrive in the middle of it,
//! and it writes one marker per job id to its own kv before it settles the job. That marker is the
//! point of the fixture: a job handled twice leaves `2` behind, and the host test
//! (`services::tests`) fails on it. So "the swap completed the job exactly once, with no second send"
//! is a number in the component's own store, not a claim in the log.
//!
//! The three modes the swap has to keep honest, all driven by `config`:
//!
//! * **cooperative** (default): `wa:kernel/drain.draining()` is read between two jobs; when a swap
//!   asks, the guest settles what it holds and calls `idle()`, so the kernel stops it with nothing in
//!   flight and hands nothing back for a retry;
//! * **`never_idle`**: the same loop with the hook ignored. The swap must fall back to its old
//!   behaviour - stop, hand the lease back, let the replacement retry - after the drain deadline, and
//!   say so;
//! * **`crash`**: a non-zero exit, for the supervisor's restart path (unchanged by this fixture).
//!
//! It logs counts and job ids only: a payload here is a marker, and a log line is never a payload.
wit_bindgen::generate!({ path: "wit", world: "svc-drain", generate_all });

use std::time::Duration;
use wa::kernel::{drain, kv, lifecycle, log};
use wa::queue::types::{Error as QueueFault, State as JobState};
use wa::queue::worker::{self, TakeOutcome};
use wasi::clocks::monotonic_clock;

/// The queue the manifest grants (`capabilities.queue.namespaces = ["wa.drain"]`).
const QUEUE: &str = "wa.drain";
/// The worker id inside the queue. The host scopes it by instance (`<name>#<generation>:<this>`), so a
/// lease is attributable to the instance that took it and a swap can hand exactly that instance's
/// leases over.
const WORKER: &str = "svc-drain";
/// Long enough that a swap lands in the middle of a handle, short enough for a test to watch.
const DEFAULT_HANDLE_MS: u64 = 700;
const LEASE_MS: u64 = 30_000;

struct Service;

impl exports::wa::kernel::service::Guest for Service {
    async fn run(config: String) -> Result<(), String> {
        let config: serde_json::Value = serde_json::from_str(&config).unwrap_or_default();
        if config["crash"] == true {
            line("crashing on purpose");
            std::process::exit(3);
        }
        // A component that ignores the drain: the deadline path, which must end exactly as a swap did
        // before the drain existed (`services::replace`'s old behaviour).
        let never_idle = config["never_idle"].as_bool().unwrap_or(false);
        let handle_ms = config["handle_ms"].as_u64().unwrap_or(DEFAULT_HANDLE_MS);
        let tick = Duration::from_millis(config["tick_ms"].as_u64().unwrap_or(50));
        line(&format!("svc-drain start idle_hook={}", !never_idle));
        lifecycle::report(lifecycle::Health::Ready, None);
        loop {
            if lifecycle::stopping() {
                line("stopping cleanly");
                return Ok(());
            }
            // The drain, read where the guest decides what to do next: between two jobs, so the one in
            // hand is always finished and settled before this can be true. Reporting idle is a promise
            // that nothing is in flight - the kernel stops the instance as soon as it reads it.
            if !never_idle && drain::draining() {
                line("draining: idle, no work in flight");
                drain::idle();
                // Returning is what the last run of this instance does. The runner treats a run that
                // reported idle as stopping, never as a crash to restart (`services.rs`), so this
                // instance cannot come back beside the one that replaced it.
                return Ok(());
            }
            match worker::take(QUEUE.to_string(), WORKER.to_string(), Some(LEASE_MS)).await {
                Ok(TakeOutcome::Taken(lease)) => {
                    let id = lease.job.id;
                    line(&format!("handling job={id}"));
                    wait(Duration::from_millis(handle_ms)).await;
                    // The effect of the job, before it is settled: a second handle of the same job
                    // makes this 2, which is exactly the duplicate a swap must not cause.
                    let marker = format!("handled/{id}");
                    let seen: u32 = kv::get(marker.clone().into_bytes())
                        .await
                        .ok()
                        .flatten()
                        .and_then(|bytes| String::from_utf8(bytes).ok())
                        .and_then(|text| text.parse().ok())
                        .unwrap_or(0);
                    let _ = kv::set(marker.into_bytes(), (seen + 1).to_string().into_bytes()).await;
                    match worker::done(QUEUE.to_string(), id, WORKER.to_string(), format!("handled {id}").into_bytes()).await {
                        Ok(job) if job.state == JobState::Done => line(&format!("settled job={id}")),
                        Ok(job) => line(&format!("settle job={id} state={job:?}")),
                        Err(error) => line(&format!("settle refused job={id} {}", fault(&error))),
                    }
                }
                Ok(TakeOutcome::Empty) => wait(tick).await,
                Ok(TakeOutcome::Busy(_)) => wait(tick).await,
                Err(error) => {
                    line(&format!("take refused {}", fault(&error)));
                    wait(tick).await;
                }
            }
        }
    }
}

/// `wasi:clocks/monotonic-clock@0.3.0.wait-for`: the guest task suspends, the runtime keeps running.
async fn wait(for_: Duration) {
    monotonic_clock::wait_for(for_.as_nanos() as u64).await;
}

/// A queue fault as its own word, never as a formatted payload.
fn fault(error: &QueueFault) -> String {
    match error {
        QueueFault::Refused(reason) => format!("refused({reason})"),
        QueueFault::Invalid(reason) => format!("invalid({reason})"),
        QueueFault::NotFound => "not-found".to_string(),
        QueueFault::LeaseLost => "lease-lost".to_string(),
        QueueFault::TooLarge(_) => "too-large".to_string(),
        QueueFault::Full(_) => "full".to_string(),
        QueueFault::Again => "again".to_string(),
        QueueFault::Failed(_) => "failed".to_string(),
    }
}

/// One line into the service log, through the kernel's log (the same file stdout goes to).
fn line(text: &str) {
    log::write(log::Level::Info, "svc-drain", text);
    println!("{text}");
}

export!(Service);
