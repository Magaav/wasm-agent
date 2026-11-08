//! `wa-stt-remote` — queue phase 2: the same `stt.requests` queue, worked from another node.
//!
//! Phase 1 of the shared queue (`wa-queue`, `docs/QUEUE.md`) is one queue per component, served by
//! the host over `wa:queue`. Phase 2 is the same queue with workers on the owner's other nodes: a
//! node whose config carries the `stt_worker` role long-polls the producing node's queue through the
//! relay (the existing signed node call), downloads the audio, decodes it with its own warm
//! faster-whisper, and streams segments back as progress. The lease is one key on the producer, so
//! the first worker wins and a worker that vanishes costs only its lease.
//!
//! This crate is the part that does not belong to the host or the component: the **request
//! payload**, the **wire envelope**, the **preference policy** and the **worker loop**. It has no
//! wasmtime, no threads and no I/O, so the two-node simulation below runs two queues, two clocks and
//! a relay in one process (`sim`), and the host/component only supply the pieces they alone can:
//! the kv, the clock, the relay POST and the recognizer.
//!
//! Shape:
//!
//! ```text
//!        producing node (openclaw, 2 cores)                    owner's other node (16 threads)
//!        ┌────────────────────────────────┐                    ┌──────────────────────────────┐
//!        │ stt.requests queue (wa-queue)  │  signed take/beat  │ stt_worker role:            │
//! enqueue │  payload = SttRequest (no text)│◀────progress──────▶│  poll → decode → segments   │
//! ───────▶│  audio: inline | fetch handle  │──────done/fail────▶│  warm faster-whisper        │
//!        │ local worker (the fallback)    │                    └──────────────────────────────┘
//!        └────────────────────────────────┘
//! ```
//!
//! The rules this crate keeps, and where they are proved:
//!
//! * **First lease wins** — one queue (`request`, `producer`), one lease rule (`wa-queue`).
//! * **Never decode stale, never post late** — checked before the decode *and* before the settle
//!   (`worker::Decoder`), so a job that goes stale in flight is dropped rather than posted late.
//! * **Remote first, local after a short wait** — `policy::Preference`; the local worker does not
//!   take a job the remote is expected to take until the grace expires, so nothing waits on a
//!   missing node.
//! * **Audio crosses only between the owner's own nodes** — `protocol::Admission` refuses a caller
//!   that is not in the owner's node list, and the payload's fetch handle expires (`request`).
//! * **Nothing logged but ids and timings** — `metrics` (the request is opaque as far as `Debug`
//!   goes, and a segment's text is never in a log line).
//!
//! Design notes that decide behaviour: `docs/QUEUE.md` ("Phase 2") and
//! `docs/WHATSAPP-TRANSCRIPTION.md` ("Remote workers").

pub mod fabric;
pub mod metrics;
pub mod policy;
pub mod producer;
pub mod protocol;
pub mod request;
pub mod sim;
pub mod worker;

#[cfg(test)]
mod tests;

pub use fabric::{decide as fabric_decide, place as fabric_place};
pub use metrics::{JobTrace, Metrics, Who};
pub use policy::{Decision, Latency, LocalReason, Preference, RemoteHealth};
pub use producer::{AudioStore, LocalWorker, MemoryAudioStore, Producer, SttPolicy};
pub use protocol::{Admission, Envelope, Op, Refusal, Reply};
pub use request::{AudioSource, FetchHandle, Mime, RequestError, SttRequest};
pub use sim::{Relay, SimNode};
pub use worker::{Decoder, JobSink, LocalSink, Outcome, Recognizer, RecognizerError, Segment, Transcript, Transport, WireError};
