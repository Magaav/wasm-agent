//! Fixture for the three host providers of the p2c job, on `wa:kernel@0.2` (WASI 0.3, native async).
//!
//! It does what the docs say a component will do, and prints one line per fact so
//! `scripts/test.sh` can assert on the service log instead of guessing:
//!
//! * **state** (`docs/STATE.md`): the kv note this component owns. A v1 install finds no note and
//!   writes `note`; the host's transactional install then migrates it to `note/v2` for a manifest
//!   that declares `state_version: 2`, so the next start reads `note/v2` and says so. A start that
//!   still sees `note` is a migration that did not run - the failure this fixture exists to make
//!   visible.
//! * **queue** (`docs/QUEUE.md`): enqueue (twice with one dedupe key), take, progress, done, and read
//!   the progress back as a stream. Then one refusal: a queue name the manifest does not grant.
//! * **bus** (`docs/BUS.md`): subscribe to its own topic, publish, receive its own event, publish a
//!   `done` fact. Then one refusal: a topic outside its namespace that is not granted.
//!
//! Nothing here reads a secret, dials a network address or writes a file, so the manifest declares
//! only `storage`, `queue` and `bus`.
wit_bindgen::generate!({ path: "wit", world: "svc-queue-echo", generate_all });

use std::time::Duration;
use wa::bus::types::{Event, Overflow, SubscriptionOptions};
use wa::bus::{publisher, subscriber};
use wa::kernel::{kv, lifecycle, log};
use wa::queue::types::{
    Error as QueueFault, Request as QueueRequest, State as JobState,
};
use wa::queue::worker::TakeOutcome;
use wa::queue::{admin, producer, worker};
use wasi::clocks::monotonic_clock;

/// The queue this fixture is granted (`capabilities.queue.namespaces = ["wa.svc"]`).
const QUEUE: &str = "wa.svc";
/// Its bus namespace is its installed name, so a subscription to this topic needs no grant - and the
/// manifest grants it anyway, to exercise the grant path rather than the default.
const TOPIC: &str = "svc-queue-echo.self";

struct Service;

impl exports::wa::kernel::service::Guest for Service {
    async fn run(config: String) -> Result<(), String> {
        let config: serde_json::Value = serde_json::from_str(&config).unwrap_or_default();
        // A crash mode, as the 0.1/0.2 echo fixtures have: the supervisor's restart path is a
        // separate thing and this fixture does not change it.
        if config["crash"] == true {
            line("crashing on purpose");
            std::process::exit(3);
        }

        state_probe().await;
        queue_probe(config["attempt"].as_bool().unwrap_or(false)).await;
        bus_probe().await;

        lifecycle::report(lifecycle::Health::Ready, None);
        let tick = Duration::from_millis(config["tick_ms"].as_u64().unwrap_or(200));
        loop {
            if lifecycle::stopping() {
                line("stopping cleanly");
                return Ok(());
            }
            line("heartbeat");
            wait(tick).await;
        }
    }
}

/// `wasi:clocks/monotonic-clock@0.3.0.wait-for`: the guest task suspends, the runtime keeps running.
async fn wait(for_: Duration) {
    monotonic_clock::wait_for(for_.as_nanos() as u64).await;
}

/// One line into the service log, through the kernel's log (the same file stdout goes to).
fn line(text: &str) {
    log::write(log::Level::Info, "svc-queue-echo", text);
    println!("{text}");
}

/// Which shape of its own key this namespace holds (`docs/STATE.md`).
async fn state_probe() {
    match kv::get(b"note/v2".to_vec()).await.ok().flatten() {
        Some(value) => {
            // `note` must be gone: the v1 -> v2 step is a rename, so a leftover would mean the
            // migration ran halfway.
            let leftover = kv::get(b"note".to_vec()).await.ok().flatten().is_some();
            if leftover {
                line("state v2 stale (note survived the migration)");
            } else {
                line(&format!("state v2 migrated value={}", String::from_utf8_lossy(&value)));
            }
        }
        None => match kv::get(b"note".to_vec()).await.ok().flatten() {
            Some(value) => line(&format!("state v1 unmigrated value={}", String::from_utf8_lossy(&value))),
            None => {
                let _ = kv::set(b"note".to_vec(), b"written at v1".to_vec()).await;
                line("state v1 fresh (wrote note)");
            }
        },
    }
}

/// produce -> consume -> done, plus one refusal.
async fn queue_probe(attempt_refusal: bool) {
    let request = QueueRequest {
        queue: QUEUE.to_string(),
        payload: b"echo".to_vec(),
        priority: 5,
        not_before_ms: None,
        fresh_for_ms: Some(60_000),
        max_attempts: Some(2),
        // One key for every boot: the second enqueue of the same key must be a dedupe hit, which is
        // the producer-side property the whole crate is built around.
        dedupe_key: Some("boot".to_string()),
        deadline_in_ms: None,
    };
    let first = match producer::enqueue(request.clone()).await {
        Ok(enqueued) => enqueued,
        Err(error) => {
            line(&format!("queue enqueue failed {error:?}"));
            return;
        }
    };
    let second = producer::enqueue(request).await;
    let deduped = matches!(second, Ok(enqueued) if enqueued.deduped);
    let job = first.job;

    match worker::take(QUEUE.to_string(), "svc-queue-echo".to_string(), None).await {
        Ok(TakeOutcome::Taken(lease)) => {
            let chunk = b"part-1".to_vec();
            let seq = worker::progress(QUEUE.to_string(), job, chunk).await.unwrap_or(u64::MAX);
            let done = worker::done(QUEUE.to_string(), job, "svc-queue-echo".to_string(), b"ok".to_vec()).await;
            let state = match &done {
                Ok(job) => format!("{:?}", job.state),
                Err(error) => format!("error {error:?}"),
            };
            // The progress chunks as the guest sees them: a stream of `list<u8>` after `after = 0`.
            let mut chunks = 0usize;
            let mut stream = producer::progress(job, 0);
            while let Some(_chunk) = stream.next().await {
                chunks += 1;
            }
            line(&format!(
                "queue ok job={job} deduped={deduped} seq={seq} chunks={chunks} lease_until={} state={state}",
                lease.lease_until_ms
            ));
            debug_job_state(job).await;
            // The admin surface: counts for the granted queue, and nothing about any other queue.
            match admin::stats(QUEUE.to_string()).await {
                Ok(stats) => line(&format!(
                    "queue stats ready={} done={} leased={} dead={}",
                    stats.ready, stats.done, stats.leased, stats.dead
                )),
                Err(error) => line(&format!("queue stats failed {error:?}")),
            }
        }
        Ok(TakeOutcome::Empty) => line("queue take empty"),
        Ok(TakeOutcome::Busy(n)) => line(&format!("queue take busy {n}")),
        Err(error) => line(&format!("queue take failed {error:?}")),
    }

    // The namespace gate: `other.queue` is not in the manifest grant, so the provider refuses it.
    // Only attempted once (`attempt` in the config) so the steady-state log stays short.
    if attempt_refusal {
        let refused = producer::enqueue(QueueRequest {
            queue: "other.queue".to_string(),
            payload: b"x".to_vec(),
            priority: 0,
            not_before_ms: None,
            fresh_for_ms: None,
            max_attempts: None,
            dedupe_key: None,
            deadline_in_ms: None,
        })
        .await;
        match refused {
            Err(QueueFault::Refused(reason)) => line(&format!("queue refused {reason}")),
            other => line(&format!("queue refusal missing {other:?}")),
        }
    }
}

/// The job as the admin surface reports it: counts and states, never a payload.
async fn debug_job_state(job: u64) {
    match producer::get(job).await {
        Ok(job) => line(&format!("queue job state={:?} attempts={}", job.state, job.attempts)),
        Err(error) => line(&format!("queue job failed {error:?}")),
    }
}

/// A publish, and the same fact read back from its own subscription.
async fn bus_probe() {
    let options = SubscriptionOptions { capacity: 8, overflow: Overflow::DropOldest };
    let mut events = match subscriber::subscribe(TOPIC, options, None) {
        Ok(stream) => stream,
        Err(error) => {
            line(&format!("bus subscribe failed {error:?}"));
            return;
        }
    };
    let event = Event {
        id: 0,
        topic: TOPIC.to_string(),
        ts_ms: 0,
        source: String::new(),
        schema: "wa.fixture.self".to_string(),
        schema_version: 1,
        trace: None,
        payload: b"hello".to_vec(),
    };
    let report = match publisher::publish(event).await {
        Ok(report) => report,
        Err(error) => {
            line(&format!("bus publish failed {error:?}"));
            return;
        }
    };
    // The subscription is a stream: the next item is our own event, with `source` set by the host.
    match events.next().await {
        Some(received) => line(&format!(
            "bus ok matched={} delivered={} topic={} source={} schema={} payload={}",
            report.matched,
            report.delivered,
            received.topic,
            received.source,
            received.schema,
            String::from_utf8_lossy(&received.payload)
        )),
        None => line("bus receive failed (stream ended)"),
    }

    let done = Event {
        id: 0,
        topic: "svc-queue-echo.done".to_string(),
        ts_ms: 0,
        source: String::new(),
        schema: "wa.fixture.done".to_string(),
        schema_version: 1,
        trace: None,
        payload: b"done".to_vec(),
    };
    match publisher::publish(done).await {
        Ok(report) => line(&format!("bus done delivered={}", report.delivered)),
        Err(error) => line(&format!("bus done failed {error:?}")),
    }

    // A topic and a pattern this component does not hold: the ACL refuses, and the guest sees it.
    match subscriber::subscribe("other.thing", SubscriptionOptions { capacity: 4, overflow: Overflow::DropOldest }, None) {
        Ok(_) => line("bus refusal missing"),
        Err(error) => line(&format!("bus refused {error:?}")),
    }
}

/// Unused-state check: the compiler must keep `JobState` reachable from the fixture's public shape.
const _: Option<JobState> = None;

export!(Service);
