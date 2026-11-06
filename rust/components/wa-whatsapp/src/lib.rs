//! WhatsApp linked-device client as a service component on `wa:kernel@0.2` (WASI 0.3).
//!
//! whatsapp-rust's protocol core, with everything that touches the outside world supplied by the
//! host: the websocket (`wa:kernel/websocket`, TLS in the host), HTTP (`wa:kernel/http`), the
//! recognizer (`wa:kernel/speech`), the clock (WASI) and stop (`wa:kernel/lifecycle`).
//!
//! Native async: there is no reactor and no polling loop over host I/O. The inbound websocket
//! frames are a `stream<list<u8>>` the socket task awaits, an exchange is one `http.send`, the
//! recognizer yields a segment stream plus one transcript future, and timers are
//! `wasi:clocks@0.3.0.wait-for`. The only executor left is the one the protocol crate insists on
//! (`Runtime::spawn`), and it is a plain set of futures joined with the main loop.
//!
//! Milestone 1: pair (by code when `pair_phone` is configured, else QR), connect, receive. The log
//! carries the pairing code, connection state and message metadata (chat, kind, id) - never content.
//! Store: store.rs - in-memory reads with write-through of durable state to the host (wa_kv);
//! a restart reconnects without pairing again.
//!
//! The crate is split so the decisions can be tested on the host: `queue` (freshness, retry, the
//! express lane), `posting` (allowlist gate, holds, chunks, edit pacing), `alerts` (own-chat log,
//! group titles), `holds` (chats held until a revoke is proven), `recognize` (the segment stream +
//! transcript future as one job, with the timings a shadow run compares) and `telemetry` (the
//! stable `wa-transcript key=value` log lines) are pure logic with no host call and no wasm target
//! requirement; everything else (`guest`, `wasm`) needs the wasm32-wasip2 bindings and is compiled
//! only for that target, so `cargo test` runs the decisions natively while
//! `cargo build --target wasm32-wasip2` builds the component.
pub mod alerts;
pub mod holds;
/// The explicit-send outbox's wire shape (quote, mentions, the exact chat) and its retry rule: pure,
/// so `cargo test` pins it natively while the guest loop that uses it stays wasm-only.
pub mod outbox;
pub mod posting;
pub mod queue;
pub mod recognize;
pub mod telemetry;

#[cfg(target_arch = "wasm32")]
mod store;

#[cfg(target_arch = "wasm32")]
wit_bindgen::generate!({
    // The component's own world: the kernel service contract plus `wa:queue/worker`, the outbox
    // seam (`wit/wa.wit`). `wit/deps/` carries snapshots of the two published contracts.
    world: "whatsapp-service",
    path: "wit",
    generate_all,
});

/// The service itself (host I/O, protocol, pipeline). Declared after `generate!` so the generated
/// `export!` macro is in textual scope inside it.
#[cfg(target_arch = "wasm32")]
mod guest;
