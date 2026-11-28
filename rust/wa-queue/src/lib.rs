//! `wa-queue` — one durable queue for every stream of work a component hands to a worker.
//!
//! The same shape is needed by the WhatsApp channel (audio to transcribe, transcripts to post),
//! OCR, and agent sub-tasks: *enqueue a job, let a worker lease it, never run work that has gone
//! stale, retry with backoff, dead-letter what keeps failing, and tell the operator once — not once
//! per item — when something did not finish in time.* Today each of those re-implements it; this
//! crate is the one implementation.
//!
//! Properties, and how they are kept:
//!
//! - **Durable.** All state lives in a [`Kv`]: job records (`j\0<id>`), an ordered ready/leased
//!   index (`i\0<queue>\0<state><priority><id>`), dedupe keys (`d\0<queue>\0<key>`), append-only
//!   progress entries (`p\0<id>\0<seq>`) and alert records (`a\0<id>\0<kind>`). There is no
//!   in-process state at all, so a restart is a new [`Queue`] over the same bytes.
//! - **Fresh-only.** A job past `fresh_until` is dropped *without running* and recorded (state
//!   [`JobState::Expired`] plus an alert). [`Queue::take`] enforces this by itself, so a sweeper
//!   that never ran cannot cause old work to be executed; [`Queue::expire_stale`] is the bulk sweep,
//!   not the safety net.
//! - **Leased.** [`Queue::take`] hands out a visibility lease; [`Queue::heartbeat`] extends it;
//!   [`Queue::done`] and [`Queue::fail`] settle it. A lease that stops being extended while the
//!   process is gone expires on a later call and the job becomes takeable again — no lease table
//!   survives a crash by being trusted.
//! - **Deterministic.** Every deadline comes from an injected [`Clock`]. No random jitter, no
//!   `Instant::now()`: the same operations at the same times produce the same state.
//! - **Bounded.** Priority order, FIFO within a priority, a per-queue concurrency limit and a
//!   per-queue readiness cap; alerts are rate limited, batched and expire.
//!
//! Deliberate non-goals: no wasmtime, no threads, no I/O, no cross-process locking. It is a library
//! over [`Kv`]; the host owns the namespace, and one writer per namespace is assumed (the kernel's
//! `kv` grant is per component, which is exactly one writer).
//!
//! ```no_run
//! use std::sync::Arc;
//! use wa_queue::{Clock, EnqueueRequest, Kv, MemoryKv, Policy, Queue, SystemClock, TakeOutcome};
//!
//! let kv = Arc::new(MemoryKv::new());
//! let clock = Arc::new(SystemClock);
//! let queue = Queue::new(kv, clock, Policy::default());
//! let enqueued = queue.enqueue(EnqueueRequest::new("stt", b"audio".to_vec()))?;
//! if let TakeOutcome::Job(job) = queue.take("stt", "worker-1", None)? {
//!     queue.heartbeat(job.id, "worker-1", None)?;
//!     queue.done(job.id, b"transcript")?;
//! }
//! # Ok::<(), wa_queue::QueueError>(())
//! ```
//!
//! Design and the WhatsApp mapping: `docs/QUEUE.md`. The WIT draft: `wit/queue/queue.wit`.

mod clock;
mod codec;
mod kv;
mod queue;

#[cfg(test)]
mod tests;

pub use clock::{Clock, FixedClock, SystemClock};
pub use kv::{Entries, Kv, KvError, MemoryKv, Prefixed};
pub use queue::Queue;


// The vocabulary is one crate, owned by the queue and shared with the component that serves the same
// words to a guest. Every name that used to be defined here still resolves here.
pub use wa_queue_contract::*;

impl From<KvError> for QueueError {
    fn from(error: KvError) -> Self {
        QueueError::Kv(error.0)
    }
}
